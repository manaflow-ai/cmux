@testable import CmuxNextMetrics
import CmuxNextTrace
import Darwin
import Foundation
import Testing

/// libmalloc's allocation hook type (`malloc_logger_t`): type flags, three arguments, the result, frames to skip.
private typealias MallocLogger = @convention(c) (UInt32, UInt, UInt, UInt, UInt, UInt32) -> Void

/// The hook's state. Only the counted thread writes `allocations`; `thread` changes only while no hook is installed.
nonisolated private enum MallocTally {
    /// The mach port of the thread being counted; 0 (`MACH_PORT_NULL`) while none is.
    nonisolated(unsafe) static var thread: UInt32 = 0
    /// Allocations that thread made since counting began.
    nonisolated(unsafe) static var allocations = 0
    /// Where the control allocation's address goes, so the optimizer keeps the allocation.
    nonisolated(unsafe) static var sink: UnsafeMutableRawPointer?
}

/// Counts the counted thread's allocations (and reallocations); it allocates nothing itself.
nonisolated private func tallyMalloc(type: UInt32, arg1: UInt, arg2: UInt, arg3: UInt, result: UInt, skip: UInt32) {
    let allocate: UInt32 = 2  // MALLOC_LOG_TYPE_ALLOCATE
    guard type & allocate != 0, pthread_mach_thread_np(pthread_self()) == MallocTally.thread else { return }
    MallocTally.allocations += 1
}

/// The histogram buckets, the metrics file and the delta upload (p09-observability task 052). Run in Release
/// (`swift test -c release --filter CmuxNextMetricsTests`): the optimized record path is what ships.
@Suite("Histograms", .serialized)
struct HistogramTests {
    private static let day = MetricsProfile.Day(year: 2026, month: 10, day: 26)

    private static func profile(_ day: MetricsProfile.Day = HistogramTests.day) -> MetricsProfile {
        MetricsProfile(appVersion: "1.2.3", buildNumber: "45", channel: "nightly", osVersion: "26.1.0",
                       hardwareClass: "Mac16,10", bootSessionUUID: Array(0 ..< 16), buildUUID: Array(16 ..< 32), buildDay: day)
    }

    /// A fresh runtime with a fresh store attached, and the store.
    private static func attachedStore(_ day: MetricsProfile.Day = HistogramTests.day,
                                      catalog: [HistogramID] = HistogramID.allCases) -> (Metrics, MetricsStore) {
        let runtime = TraceRuntime(role: .app)
        let store = MetricsStore(role: .app, profile: profile(day), pid: 4242, catalog: catalog)
        #expect(store.attach(to: runtime))
        return (Metrics(runtime: runtime), store)
    }

    private static func histogram(_ id: HistogramID, in delta: MetricsDelta) -> MetricsDelta.Histogram? {
        delta.histograms.first { $0.name == id.name }
    }

    private static func temporaryDirectory() -> String {
        FileManager.default.temporaryDirectory.appending(path: "metrics-tests-\(UUID().uuidString)").path
    }

    // MARK: buckets

    /// The golden of cmux-tui/crates/cmux-trace/tests/fixtures (cmux-tui-core's `bucket_golden_tests` reads it too).
    @Test("The log-linear edges match Rust's for 1000 random values")
    func logLinearEdgesMatchTheRustGolden() throws {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0 ..< 6 { root.deleteLastPathComponent() }
        let url = root.appending(path: "cmux-tui/crates/cmux-trace/tests/fixtures/metrics-log-linear-golden.txt")
        let text = try String(contentsOf: url, encoding: .utf8)
        var checked = 0
        for line in text.split(separator: "\n") where !line.hasPrefix("#") {
            let fields = line.split(separator: " ").compactMap { UInt64($0) }
            try #require(fields.count == 3, "\(line)")
            let index = HistogramID.Layout.logLinearIndex(fields[0])
            #expect(index == Int(fields[1]), "value \(fields[0])")
            #expect(HistogramID.Layout.logLinearUpperBound(index) == fields[2], "index \(index)")
            #expect(HistogramID.Layout.logLinearLowerBound(index) <= fields[0])
            checked += 1
        }
        #expect(checked == 1000)
    }

    @Test("Each log-linear bucket starts one past the previous one's end; buckets 4 to 7 hold nothing")
    func logLinearBucketsTile() {
        for value: UInt64 in 0 ..< 4 { #expect(HistogramID.Layout.logLinearIndex(value) == Int(value)) }
        #expect(HistogramID.Layout.logLinearIndex(4) == 8)
        for index in 8 ..< 255 {
            #expect(HistogramID.Layout.logLinearLowerBound(index + 1) == HistogramID.Layout.logLinearUpperBound(index) + 1, "\(index)")
        }
        #expect(HistogramID.Layout.logLinearUpperBound(255) == UInt64.max)
        #expect(HistogramID.Layout.logLinearIndex(.max) == 255)
    }

    @Test("Samples below 0 count as 0, above the maximum in the overflow bucket, and each bucket's range holds its samples")
    func layoutsPlaceSamples() throws {
        let logLinear = HistogramID.Layout.logLinear(maximum: 60_000_000)
        #expect(logLinear.bucketIndex(of: -5) == 0)
        #expect(logLinear.bucketIndex(of: 60_000_001) == logLinear.bucketCount - 1)
        #expect(logLinear.bucketIndex(of: 60_000_000) == logLinear.bucketCount - 2)
        let linear = HistogramID.Layout.linear(maximum: 100)
        #expect(linear.bucketCount == 102)
        #expect(linear.bucketIndex(of: 100) == 100 && linear.bucketIndex(of: 101) == 101 && linear.bucketIndex(of: -1) == 0)
        let enumeration = HistogramID.Layout.enumeration(valueCount: 4)
        #expect(enumeration.bucketCount == 5)
        #expect(enumeration.bucketIndex(of: 3) == 3 && enumeration.bucketIndex(of: 4) == 4 && enumeration.bucketIndex(of: -1) == 4)
        #expect(HistogramID.Layout.chromium.bucketIndex(of: 1) == nil && HistogramID.Layout.chromium.bucketCount == 0)
        var generator = SystemRandomNumberGenerator()
        for layout in [logLinear, HistogramID.Layout.logLinear(maximum: 3_600_000), linear, enumeration] {
            for _ in 0 ..< 1_000 {
                let sample = Int64.random(in: 0 ... 1 << Int64.random(in: 0 ... 40, using: &generator), using: &generator)
                let index = try #require(layout.bucketIndex(of: sample))
                let range = try #require(layout.bucketRange(index), "\(layout) \(index)")
                #expect(range.contains(sample), "\(layout): \(sample) in bucket \(index) \(range)")
            }
        }
    }

    // MARK: expiry

    @Test("An expired histogram has no block and records nothing; the day of its expiry still records")
    func expiredHistogramsRecordNothing() {
        let expiring = HistogramID.mainCongestion(.exec, .launch)
        #expect(expiring.expiry == .after(year: 2027, month: 4, day: 30))
        let (late, lateStore) = Self.attachedStore(MetricsProfile.Day(year: 2027, month: 5, day: 1))
        #expect(!lateStore.histograms.contains(expiring))
        #expect(lateStore.histograms.contains(.keyFrame(.view)), "a histogram that never expires keeps its block")
        late.record(expiring, 12)
        late.record(.keyFrame(.view), 12)
        #expect(Self.histogram(expiring, in: lateStore.delta()) == nil)
        #expect(Self.histogram(.keyFrame(.view), in: lateStore.delta())?.count == 1)

        let (onTheDay, store) = Self.attachedStore(MetricsProfile.Day(year: 2027, month: 4, day: 30))
        onTheDay.record(expiring, 12)
        #expect(Self.histogram(expiring, in: store.delta())?.count == 1)
    }

    @Test("Chromium's own histograms have no block")
    func chromiumHistogramsHaveNoBlock() {
        let (metrics, store) = Self.attachedStore()
        #expect(!store.histograms.contains { if case .chromium = $0 { true } else { false } })
        metrics.record(.chromium(.allCases[0]), 5)
        #expect(store.delta().isEmpty)
    }

    // MARK: delta upload

    @Test("Two snapshots send each sample once")
    func deltasSendEachSampleOnce() throws {
        let (metrics, store) = Self.attachedStore()
        for sample: Int64 in [3, 250, 250, 9_000] { metrics.record(.keyFrame(.terminal), sample) }
        metrics.record(.stabilityUncleanExit, HistogramID.UncleanExit.killed.rawValue)
        let first = store.delta()
        let keyFirst = try #require(Self.histogram(.keyFrame(.terminal), in: first))
        #expect(keyFirst.count == 4 && keyFirst.sum == 9_503)
        #expect(keyFirst.buckets.reduce(0) { $0 + $1.count } == 4)
        #expect(Self.histogram(.stabilityUncleanExit, in: first)?.buckets == [MetricsDelta.Bucket(index: 2, count: 1)])
        #expect(store.delta() == first, "a delta that is not marked logged is sent again")
        store.markLogged(first)

        metrics.record(.keyFrame(.terminal), 250)
        metrics.record(.keyFrame(.terminal), 70_000_000)
        let second = store.delta()
        let keySecond = try #require(Self.histogram(.keyFrame(.terminal), in: second))
        #expect(keySecond.count == 2 && keySecond.sum == 70_000_250)
        let overflow = HistogramID.keyFrame(.terminal).layout.bucketCount - 1
        let bucket250 = HistogramID.Layout.logLinearIndex(250)
        #expect(keySecond.buckets == [MetricsDelta.Bucket(index: bucket250, count: 1), MetricsDelta.Bucket(index: overflow, count: 1)])
        #expect(Self.histogram(.stabilityUncleanExit, in: second) == nil)
        store.markLogged(second)
        #expect(store.delta().isEmpty)
        #expect(first.profile == Self.profile())
    }

    /// What an uploader sent: the marked deltas' totals and the largest count one delta held.
    private struct Uploads: Sendable {
        var count: UInt64 = 0
        var sum: UInt64 = 0
        var largest: UInt64 = 0
        var deltas = 0

        /// Takes a delta of `.mainTurn` and marks it logged, as the report uploader does after an upload.
        mutating func upload(from store: MetricsStore) {
            let delta = store.delta()
            guard let turn = delta.histograms.first(where: { $0.name == HistogramID.mainTurn.name }) else { return }
            count += turn.count
            sum += turn.sum
            largest = max(largest, turn.count)
            deltas += 1
            store.markLogged(delta)
        }

        /// Uploads in a loop until `store` is file-backed.
        static func untilAdopted(_ store: MetricsStore) -> Uploads {
            var uploads = Uploads()
            while !store.isFileBacked { uploads.upload(from: store) }
            return uploads
        }
    }

    /// The adoption folds the heap's counters and logged shadow into the file while an uploader takes and marks
    /// deltas on another thread: a delta must never see the file half folded (a count of about 2^64 from current 0
    /// minus logged 10) and a mark must never land in the heap after the fold read it (its samples sent again).
    @Test("Deltas marked while the adoption folds the heap into the file send each sample once")
    func deltasDuringAdoptionSendEachSampleOnce() async throws {
        let records = 2_000
        let expectedSum = (0 ..< records).reduce(UInt64(0)) { $0 + UInt64($1) }
        for _ in 0 ..< 50 {
            let directory = Self.temporaryDirectory()
            defer { try? FileManager.default.removeItem(atPath: directory) }
            let (metrics, store) = Self.attachedStore()
            async let uploading = Uploads.untilAdopted(store)
            for index in 0 ..< records { metrics.record(.mainTurn, Int64(index)) }
            _ = try #require(store.adoptFile(directory: directory))
            var uploads = await uploading
            uploads.upload(from: store)
            #expect(uploads.largest <= UInt64(records), "a delta never holds more samples than were recorded")
            #expect(uploads.count == UInt64(records) && uploads.sum == expectedSum, "each sample is sent once")
            #expect(store.delta().isEmpty)
        }
    }

    // MARK: record path

    @Test("A thousand records make no heap allocation")
    func recordsMakeNoMallocs() throws {
        // RTLD_DEFAULT, a C macro Swift does not import.
        let symbol = try #require(dlsym(UnsafeMutableRawPointer(bitPattern: -2), "malloc_logger"), "libmalloc exports malloc_logger")
        let hook = symbol.assumingMemoryBound(to: MallocLogger?.self)
        let (metrics, store) = Self.attachedStore()
        let ids: [HistogramID] = [.keyFrame(.view), .mainTurn, .smoothnessDroppedPercent(.motion), .stabilityUncleanExit,
                                  .memory(.renderer), .chromium(.allCases[0])]
        // An index loop: a `for` over a range allocates in a Debug build (its iterator's read
        // coroutine frame), which would be counted against the record path.
        func records() {
            var index = 0
            while index < 1_000 {
                metrics.record(ids[index % ids.count], Int64(index) * 37)
                index += 1
            }
        }
        records()
        MallocTally.allocations = 0
        MallocTally.thread = pthread_mach_thread_np(pthread_self())
        let previous = hook.pointee
        hook.pointee = tallyMalloc
        records()
        MallocTally.sink = malloc(64)
        free(MallocTally.sink)
        hook.pointee = previous
        MallocTally.thread = 0
        #expect(MallocTally.allocations == 1, "only the control malloc is counted")
        #expect(Self.histogram(.mainTurn, in: store.delta())?.count == 334, "167 of each 1000 records, twice")
    }

    @Test("Eight threads' records all count")
    func concurrentRecordsAllCount() {
        let (metrics, store) = Self.attachedStore()
        DispatchQueue.concurrentPerform(iterations: 8) { thread in
            for index in 0 ..< 10_000 { metrics.record(.frameInterval, Int64(thread * 10_000 + index)) }
        }
        let interval = Self.histogram(.frameInterval, in: store.delta())
        #expect(interval?.count == 80_000)
        #expect(interval?.buckets.reduce(0) { $0 + $1.count } == 80_000)
        #expect(interval?.sum == (0 ..< 80_000).reduce(0) { $0 + UInt64($1) })
    }

    @Test("A duration converts to the histogram's unit")
    func durationsConvert() throws {
        let (metrics, store) = Self.attachedStore()
        metrics.record(.launchFirstFrame(.warm), duration: .milliseconds(180))
        metrics.record(.keyFrame(.view), duration: .microseconds(3_200))
        let delta = store.delta()
        #expect(Self.histogram(.launchFirstFrame(.warm), in: delta)?.sum == 180)
        #expect(Self.histogram(.keyFrame(.view), in: delta)?.sum == 3_200)
    }

    @Test("Without a store a record does nothing")
    func noStoreRecordsNothing() {
        let runtime = TraceRuntime(role: .app)
        Metrics(runtime: runtime).record(.mainTurn, 5)
        #expect(MetricsStore.attached(to: runtime) == nil)
        let store = MetricsStore(role: .app, profile: Self.profile())
        #expect(store.attach(to: runtime))
        #expect(!MetricsStore(role: .app, profile: Self.profile()).attach(to: runtime), "the first store stays")
        #expect(MetricsStore.attached(to: runtime) === store)
    }

    /// One record's cost, in ns, as the median of 1000-record batches (the `metrics-record` perf-hot bench).
    @Test("recordCost: a record stays well under a microsecond")
    func recordCost() {
        let (metrics, _) = Self.attachedStore()
        let clock = TraceClock()
        var batches: [UInt64] = []
        for _ in 0 ..< 200 {
            let start = clock.nowNanos()
            for index in 0 ..< 1_000 { metrics.record(.keyFrame(.terminal), Int64(index)) }
            batches.append((clock.nowNanos() - start) / 1_000)
        }
        let median = batches.sorted()[batches.count / 2]
        print("metrics-record: \(median) ns per record (median of \(batches.count) batches of 1000)")
        #expect(median < 1_000)
    }

    // MARK: file

    @Test("Adoption moves the counters into the file, which a reader decodes with its profile")
    func adoptionKeepsEverySample() throws {
        let directory = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let (metrics, store) = Self.attachedStore()
        for sample: Int64 in 1 ... 5 { metrics.record(.mainTurn, sample * 1_000) }
        #expect(!store.isFileBacked)
        let path = try #require(store.adoptFile(directory: directory))
        #expect(path == directory + "/metrics-app-4242.bin")
        #expect(store.isFileBacked)
        #expect(store.adoptFile(directory: directory) == nil, "adoption is one-shot")
        for sample: Int64 in 6 ... 8 { metrics.record(.mainTurn, sample * 1_000) }
        #expect(Self.histogram(.mainTurn, in: store.delta())?.count == 8)

        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        #expect((attributes[.size] as? Int) == store.byteCount)
        let descriptor = open(path, O_RDONLY | O_CLOEXEC)
        try #require(descriptor >= 0)
        defer { close(descriptor) }
        let mapping = try #require(mmap(nil, store.byteCount, PROT_READ, MAP_SHARED, descriptor, 0))
        try #require(mapping != UnsafeMutableRawPointer(bitPattern: -1))
        defer { munmap(mapping, store.byteCount) }
        let image = try #require(MetricsImage(validating: mapping, byteCount: store.byteCount))
        #expect(image.profile == Self.profile())
        #expect(image.pid == 4242 && image.role == TraceRuntime.Role.app.rawValue)
        #expect(image.names == store.histograms.map(\.name))
        let fromFile = try #require(Self.histogram(.mainTurn, in: image.delta()))
        #expect(fromFile.count == 8 && fromFile.sum == 36_000)
    }

    @Test("The next launch renames the spare instead of creating its file")
    func adoptionTakesTheSpare() throws {
        let directory = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let first = MetricsStore(role: .daemon, profile: Self.profile(), pid: 1)
        #expect(first.prepareSpare(directory: directory))
        let spare = directory + "/" + MetricsStore.spareName(role: .daemon)
        #expect(FileManager.default.fileExists(atPath: spare))
        #expect(spare.hasSuffix("/metrics-daemon.spare.bin"))
        let second = MetricsStore(role: .daemon, profile: Self.profile(), pid: 2)
        let path = try #require(second.adoptFile(directory: directory))
        #expect(!FileManager.default.fileExists(atPath: spare), "the spare became the file")
        #expect(FileManager.default.fileExists(atPath: path))
    }

    @Test("The profile round-trips through a header; long texts are cut at a character")
    func profileRoundTrips() {
        var profile = Self.profile()
        let header = UnsafeMutableRawPointer.allocate(byteCount: 1_024, alignment: 8)
        defer { header.deallocate() }
        header.initializeMemory(as: UInt8.self, repeating: 0, count: 1_024)
        profile.write(into: header)
        #expect(MetricsProfile(reading: header) == profile)

        profile.hardwareClass = String(repeating: "é", count: 40)
        header.initializeMemory(as: UInt8.self, repeating: 0, count: 1_024)
        profile.write(into: header)
        let read = MetricsProfile(reading: header)
        #expect(read.hardwareClass == String(repeating: "é", count: 31), "62 of the 63 bytes: a character is never split")
        #expect(MetricsProfile.Day(year: 2027, month: 4, day: 30) < MetricsProfile.Day(year: 2027, month: 5, day: 1))
    }
}
