@testable import CmuxNextCompat
@testable import CmuxNextTrace
import Darwin
import Foundation
import Testing

/// Task p09-observability-005: the category word, the black box's launch defaults and role sizes, the
/// black box's file steps (none on the main thread at launch) and the cleanup of dead processes' rings.
@Suite(.serialized)
struct TraceCategoriesTests {
    // MARK: categories

    /// The black box records what plans/cmux-next/trace.md marks "Black box default: yes", and nothing else.
    @Test func theBlackBoxDefaultIsTheListedSet() {
        let listed: [TraceCategories] = [.action, .key, .switch, .create, .cef, .launch, .daemon, .hang, .crash]
        #expect(TraceCategories.blackBox == TraceCategories(listed))
        #expect(TraceCategories.blackBox.rawValue == 0x1FF)
        for bit in UInt8(0) ... 8 { #expect(TraceCategories.blackBox.contains(bit: bit)) }
        for bit in UInt8(9) ... 63 { #expect(!TraceCategories.blackBox.contains(bit: bit)) }
    }

    /// Each category keeps its trace.md bit (the same as Rust's `cmux_trace::category`).
    @Test func eachCategoryKeepsItsBit() {
        let table: [(TraceCategories, UInt8)] = [
            (.action, 0), (.key, 1), (.switch, 2), (.create, 3), (.cef, 4), (.launch, 5), (.daemon, 6), (.hang, 7),
            (.crash, 8), (.motion, 9), (.frame, 10), (.stall, 11), (.task, 12), (.burst, 13), (.input, 14),
            (.webview, 15), (.remote, 16), (.control, 17), (.ghostty, 18), (.resize, 19),
        ]
        for (category, bit) in table { #expect(category == TraceCategories(bit: bit)) }
        #expect(TraceCategories.recordingAdds.rawValue == 0xF_FE00)
        #expect(TraceCategories.blackBox.isDisjoint(with: .recordingAdds))
        #expect(TraceCategories.all.rawValue == 0xF_FFFF)
    }

    /// A runtime starts with every category off; setting the black box turns on its categories only.
    @Test func theRuntimeReadsTheCategoryWord() {
        let runtime = TraceRuntime(role: .app)
        #expect(!runtime.isEnabled(.action))
        runtime.setCategories(.blackBox)
        #expect(runtime.categories == .blackBox)
        #expect(runtime.isEnabled(.key))
        #expect(runtime.isEnabled([.frame, .crash]))
        #expect(!runtime.isEnabled(.frame))
        #expect(!runtime.isEnabled(categoryBit: 10))
        #expect(runtime.isEnabled(categoryBit: 8))
    }

    // MARK: sizes

    /// The black box and recording sizes per role are trace.md's "Sizes by role" table.
    @Test func roleSizesFollowTheTable() {
        let rows: [(TraceRuntime.Role, Int, Int, Int, Int)] = [
            (.app, 4096, 2048, 512, 32768), (.daemon, 4096, 2048, 512, 32768), (.chromiumHost, 4096, 2048, 512, 8192),
            (.holder, 2048, 512, 256, 8192), (.acpmux, 2048, 512, 256, 8192), (.terminalHost, 1024, 256, 64, 512),
        ]
        for (role, names, threads, blackBox, recording) in rows {
            #expect(role.blackBoxSizes == TraceRing.Sizes(nameCapacity: names, threadCapacity: threads, chunkCount: blackBox))
            #expect(role.recordingSizes == TraceRing.Sizes(nameCapacity: names, threadCapacity: threads, chunkCount: recording))
            #expect(role.blackBoxSizes.chunkCount == blackBox)
        }
        for role in TraceRuntime.Role.allCases { #expect(role.ringRole.rawValue == role.rawValue) }
    }

    // MARK: black box

    /// Making the black box on the main thread opens, truncates and maps nothing: no blocking site, no
    /// folder, a heap ring, the black-box categories on. The file step is what the detector flags there.
    @Test func makingTheBlackBoxDoesNoFileWorkOnMain() async throws {
        #if DEBUG
        let folder = Self.temporaryFolder()
        defer { Self.remove(folder) }
        let directory = folder + "/trace"
        let runtime = TraceRuntime(role: .app)
        let table = BlockingViolationTable(mode: .record)
        let blackBox = await BlockingViolationTable.$scoped.withValue(table) {
            await MainActor.run { TraceBlackBox(role: .app, directory: directory, runtime: runtime, process: Self.facts) }
        }
        await table.flush()
        #expect(table.sites.isEmpty)
        #expect(access(directory, F_OK) != 0)
        #expect(!blackBox.ring.isFileBacked)
        #expect(runtime.categories == .blackBox)

        let adoptTable = BlockingViolationTable(mode: .record)
        await BlockingViolationTable.$scoped.withValue(adoptTable) {
            await MainActor.run { _ = blackBox.adoptFile() }
        }
        await adoptTable.flush()
        #expect(adoptTable.sites.map(\.kind) == [.fileIO])
        #endif
    }

    /// Off the main thread the steps make the ring file, keep it at cleanup (its process lives) and make the
    /// spare the next launch renames.
    @Test func theFileStepsAdoptKeepAndPrepareTheSpare() throws {
        let folder = Self.temporaryFolder()
        defer { Self.remove(folder) }
        let directory = folder + "/a/trace"
        let blackBox = TraceBlackBox(role: .terminalHost, directory: directory, runtime: TraceRuntime(role: .terminalHost),
                                     process: Self.facts)
        #expect(blackBox.adoptFile() != nil)
        #expect(blackBox.ring.isFileBacked)
        #expect(access(blackBox.filePath, F_OK) == 0)

        let report = blackBox.cleanUp(now: Self.wallClock() + Self.days(10))
        #expect(report.live == [TraceRingFile.fileName(role: .terminalHost, pid: Self.facts.pid)])
        #expect(report.deleted.isEmpty)
        #expect(access(blackBox.filePath, F_OK) == 0)

        #expect(blackBox.prepareSpare())
        #expect(access(directory + "/" + TraceRingFile.spareName(role: .terminalHost), F_OK) == 0)
    }

    // MARK: cleanup

    /// A live process's black box stays at any age; a dead one older than 3 days goes; a young dead one stays.
    @Test func cleanupKeepsLivePidFilesAndDeletesOldDeadOnes() throws {
        let folder = Self.temporaryFolder()
        defer { Self.remove(folder) }
        let now = Self.wallClock()
        try Self.write(folder, "app-100.blackbox.cmxtrace", bytes: 4096, age: Self.days(5), now: now)
        try Self.write(folder, "daemon-200.blackbox.cmxtrace", bytes: 4096, age: Self.days(5), now: now)
        try Self.write(folder, "holder-300.blackbox.cmxtrace", bytes: 4096, age: Self.days(1), now: now)
        try Self.write(folder, "app-400.recording.cmxtrace", bytes: 4096, age: Self.days(5), now: now)
        try Self.write(folder, "app.spare.cmxtrace.500.tmp", bytes: 0, age: 0, now: now)
        try Self.write(folder, "app.spare.cmxtrace.100.tmp", bytes: 0, age: 0, now: now)

        var cleanup = TraceRingCleanup(directory: folder)
        cleanup.isAlive = { pid, _ in pid == 100 }
        cleanup.nowUnixNanos = { now }
        let report = cleanup.run()

        #expect(report.live == ["app-100.blackbox.cmxtrace"])
        #expect(report.keptDead == ["holder-300.blackbox.cmxtrace"])
        #expect(Set(report.deleted) == ["daemon-200.blackbox.cmxtrace", "app.spare.cmxtrace.500.tmp"])
        #expect(Set(Self.names(folder)) == [
            "app-100.blackbox.cmxtrace", "holder-300.blackbox.cmxtrace", "app-400.recording.cmxtrace",
            "app.spare.cmxtrace.100.tmp",
        ])
    }

    /// Past 16 MiB of dead black boxes the oldest go first; a live process's ring never counts or goes.
    @Test func cleanupCapsDeadBlackBoxesOldestFirst() throws {
        let folder = Self.temporaryFolder()
        defer { Self.remove(folder) }
        let now = Self.wallClock()
        let six = 6 * 1024 * 1024
        try Self.write(folder, "app-1.blackbox.cmxtrace", bytes: six, age: Self.days(2), now: now)
        try Self.write(folder, "app-2.blackbox.cmxtrace", bytes: six, age: Self.days(1), now: now)
        try Self.write(folder, "app-3.blackbox.cmxtrace", bytes: six, age: Self.hours(1), now: now)
        try Self.write(folder, "app-4.blackbox.cmxtrace", bytes: 4 * six, age: Self.days(2), now: now)

        var cleanup = TraceRingCleanup(directory: folder)
        cleanup.isAlive = { pid, _ in pid == 4 }
        cleanup.nowUnixNanos = { now }
        let report = cleanup.run()

        #expect(report.live == ["app-4.blackbox.cmxtrace"])
        #expect(report.deleted == ["app-1.blackbox.cmxtrace"])
        #expect(report.keptDead == ["app-2.blackbox.cmxtrace", "app-3.blackbox.cmxtrace"])
    }

    /// The real process check: this process is alive, with its own start time, and not with another one.
    @Test func theProcessCheckUsesTheStartTime() {
        let pid = getpid()
        let start = TraceRingCleanup.processStartUnixMicros(pid: pid)
        #expect(start != 0)
        #expect(TraceRingCleanup.processIsAlive(pid: pid, startMicros: start))
        #expect(TraceRingCleanup.processIsAlive(pid: pid, startMicros: 0))
        #expect(!TraceRingCleanup.processIsAlive(pid: pid, startMicros: start &+ 1))
        #expect(!TraceRingCleanup.processIsAlive(pid: 0, startMicros: 0))
    }

    // MARK: helpers

    private static let facts = TraceBlackBox.ProcessFacts(pid: UInt32(bitPattern: getpid()))

    private static func days(_ count: UInt64) -> UInt64 { count * 24 * hours(1) }
    private static func hours(_ count: UInt64) -> UInt64 { count * 3600 * 1_000_000_000 }

    private static func wallClock() -> UInt64 { clock_gettime_nsec_np(CLOCK_REALTIME) }

    private static func temporaryFolder() -> String {
        var template = Array((NSTemporaryDirectory() + "trace-categories-XXXXXX").utf8CString)
        return template.withUnsafeMutableBufferPointer { String(cString: mkdtemp($0.baseAddress!)) }
    }

    private static func remove(_ folder: String) {
        try? FileManager.default.removeItem(atPath: folder)
    }

    private static func names(_ folder: String) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
    }

    /// A sparse file of `bytes` bytes last written `age` nanoseconds before `now`.
    private static func write(_ folder: String, _ name: String, bytes: Int, age: UInt64, now: UInt64) throws {
        let path = folder + "/" + name
        let descriptor = open(path, O_RDWR | O_CREAT | O_TRUNC | O_CLOEXEC, 0o600)
        try #require(descriptor >= 0)
        defer { close(descriptor) }
        try #require(ftruncate(descriptor, off_t(bytes)) == 0)
        let seconds = Int((now - age) / 1_000_000_000)
        var times = [timespec(tv_sec: seconds, tv_nsec: 0), timespec(tv_sec: seconds, tv_nsec: 0)]
        try #require(futimens(descriptor, &times) == 0)
    }
}
