import CmuxNextCompat
import CmuxNextTrace
import Darwin
import Foundation
import Testing

/// The trace ring v1 writer and decoder (p09-observability-003): per-thread chunks, the seqlock publish,
/// black-box overwrite, heap-then-file adoption and crash safety. Serialized: the 8-thread tests and
/// the contention measurement must not share the machine with each other.
@Suite(.serialized)
struct TraceRingTests {
    @Test func aWrittenRecordDecodesWithEveryField() {
        let ring = TraceRing(records: 4096, role: "test")
        for index in 0 ..< 100 {
            ring.write(name: UInt16(index), phase: .asyncBegin, flags: 1, timestamp: 1000 + UInt64(index),
                       arg0: UInt64(index), arg1: ~UInt64(index))
        }
        let records = ring.records()
        #expect(records.map(\.arg0) == (0 ..< 100).map(UInt64.init))
        let last = records.last
        #expect(last?.name == 99)
        #expect(last?.phase == .asyncBegin)
        #expect(last?.flags == 1)
        #expect(last?.timestamp == 1099)
        #expect(last?.arg1 == ~UInt64(99))
        #expect(Set(records.map(\.threadIndex)).count == 1)
        let counters = ring.counters
        #expect([counters.overwrittenChunks, counters.skippedOwnedChunks, counters.droppedRecords, counters.adoptFailures] == [0, 0, 0, 0])
        #expect(TraceRing.records(inImage: ring.image()) == records)
    }

    @Test func eightThreadsDecodeExactlyOnceInPerThreadOrder() {
        let perThread = 100_000
        let ring = TraceRing(records: 8 * perThread + 8 * 2 * TraceRing.recordsPerChunk, role: "test")
        runOnThreads(8) { tag in
            for index in 0 ..< perThread {
                ring.write(name: 7, phase: .instant, timestamp: clock_gettime_nsec_np(CLOCK_UPTIME_RAW),
                           arg0: UInt64(index), arg1: UInt64(tag))
            }
        }
        let records = ring.records()
        #expect(records.count == 8 * perThread)
        let byTag = Dictionary(grouping: records, by: \.arg1)
        #expect(byTag.count == 8)
        let expected = (0 ..< perThread).map(UInt64.init)
        for (tag, tagged) in byTag {
            #expect(tagged.map(\.arg0) == expected, "thread \(tag): its records are missing, repeated or out of order")
            #expect(Set(tagged.map(\.threadIndex)).count == 1, "thread \(tag) wrote under more than one thread index")
        }
        #expect(Set(byTag.values.compactMap { $0.first?.threadIndex }).count == 8)
        #expect(ring.counters.droppedRecords == 0)
        #expect(ring.counters.overwrittenChunks == 0)
    }

    /// Writers overwrite a small ring while a reader decodes it, live and through an image: every record
    /// the reader accepts is whole.
    @Test func aReaderNeverAcceptsATornRecord() {
        let ring = TraceRing(records: 16 * TraceRing.recordsPerChunk, role: "test")
        let writersDone = SharedCount()
        let reads = SharedCount()
        let tornLive = SharedCount()
        let tornImage = SharedCount()
        runOnThreads(5) { tag in
            if tag == 4 {
                while writersDone.value.load(ordering: .acquiring) < 4 {
                    tornLive.value.add(ring.records().filter { !Self.isWhole($0) }.count, ordering: .relaxed)
                    let imaged = TraceRing.records(inImage: ring.image()) ?? []
                    tornImage.value.add(imaged.filter { !Self.isWhole($0) }.count, ordering: .relaxed)
                    reads.value.add(1, ordering: .relaxed)
                }
                return
            }
            for index in 0 ..< 300_000 {
                Self.writeChecked(ring, value: UInt64(tag) << 32 | UInt64(index))
            }
            writersDone.value.add(1, ordering: .releasing)
        }
        #expect(reads.value.load(ordering: .relaxed) > 0)
        #expect(tornLive.value.load(ordering: .relaxed) == 0, "the live decoder accepted torn records")
        #expect(tornImage.value.load(ordering: .relaxed) == 0, "an image held torn records")
        #expect(ring.records().allSatisfy(Self.isWhole))
    }

    /// A crash mid-write leaves an odd sequence; an old lap's record or one past the published count is
    /// stale. The decoder accepts none of them.
    @Test func theDecoderSkipsUnpublishedAndStaleSlots() throws {
        let ring = TraceRing(records: 4096, role: "test")
        for index in 0 ..< 4 {
            ring.write(name: 1, phase: .instant, timestamp: UInt64(index), arg0: UInt64(index))
        }
        let image = ring.image()
        // The thread's first chunk is chunk 0 (ticket 0, lap 0), whose published sequence is 2.
        func sequenceByte(slot: Int) -> Int { TraceRing.headerBytes + slot * TraceRing.recordBytes + 8 }
        let publishedByte = TraceRing.headerBytes + 16
        #expect(try #require(TraceRing.records(inImage: image)).map(\.arg0) == [0, 1, 2, 3])

        var writing = image
        writing[sequenceByte(slot: 2)] = 1 // odd: the writer stopped inside this record
        #expect(try #require(TraceRing.records(inImage: writing)).map(\.arg0) == [0, 2, 3])

        var oldLap = image
        oldLap[sequenceByte(slot: 3)] = 4 // lap 1's sequence in a lap-0 chunk
        #expect(try #require(TraceRing.records(inImage: oldLap)).map(\.arg0) == [0, 1, 3])

        var unpublished = image
        unpublished[publishedByte] = 2
        #expect(try #require(TraceRing.records(inImage: unpublished)).map(\.arg0) == [0, 1])

        var notARing = image
        notARing[0] = 0
        #expect(TraceRing.records(inImage: notARing) == nil)
        #expect(TraceRing.records(inImage: Array(image.prefix(TraceRing.headerBytes + 10))) == nil)
    }

    /// The black box: after 10x its capacity only whole records remain, the newest of every thread among them.
    @Test func afterTenTimesCapacityOnlyWholeRecordsDecode() {
        let ring = TraceRing(records: 4096, role: "test")
        let perThread = ring.capacity * 10 / 4
        runOnThreads(4) { tag in
            for index in 0 ..< perThread {
                Self.writeChecked(ring, value: UInt64(tag) << 32 | UInt64(index))
            }
        }
        let records = ring.records()
        #expect(records.allSatisfy(Self.isWhole))
        #expect(records.count <= ring.capacity)
        #expect(records.count >= ring.capacity - 4 * TraceRing.recordsPerChunk)
        #expect(ring.counters.overwrittenChunks > 0)
        for tag in 0 ..< 4 {
            let values = records.filter { $0.arg0 >> 32 == UInt64(tag) }.map { $0.arg0 & 0xFFFF_FFFF }
            #expect(values.last == UInt64(perThread - 1), "thread \(tag)'s newest record was lost")
            #expect(zip(values, values.dropFirst()).allSatisfy { $0 < $1 }, "thread \(tag)'s records are out of order")
        }
    }

    /// A live thread's chunk is never overwritten, however far the others wrap.
    @Test func aLiveThreadsChunkIsNeverOverwritten() {
        let ring = TraceRing(records: 4 * TraceRing.recordsPerChunk, role: "test")
        let stage = SharedCount()
        let survived = SharedCount()
        runOnThreads(2) { tag in
            if tag == 0 {
                ring.write(name: 9, phase: .instant, timestamp: 0, arg0: 4242)
                stage.value.store(1, ordering: .releasing)
                while stage.value.load(ordering: .acquiring) < 2 {}
            } else {
                while stage.value.load(ordering: .acquiring) < 1 {}
                for index in 0 ..< 10 * ring.capacity {
                    ring.write(name: 1, phase: .instant, timestamp: UInt64(index + 1), arg0: UInt64(index))
                }
                let kept = ring.records().contains { $0.arg0 == 4242 && $0.name == 9 }
                survived.value.store(kept ? 1 : 0, ordering: .relaxed)
                stage.value.store(2, ordering: .releasing)
            }
        }
        #expect(survived.value.load(ordering: .relaxed) == 1, "another thread overwrote a live thread's chunk")
        #expect(ring.counters.skippedOwnedChunks > 0)
    }

    /// A thread that exits gives its chunk back: with both chunks once owned by exited threads, a third
    /// thread still finds room.
    @Test func anExitedThreadGivesItsChunkBack() {
        let ring = TraceRing(records: 2 * TraceRing.recordsPerChunk, role: "test")
        runOnThreads(2) { tag in
            ring.write(name: 1, phase: .instant, timestamp: UInt64(tag), arg0: UInt64(tag))
        }
        runOnThreads(1) { _ in
            for index in 0 ..< 100 {
                ring.write(name: 2, phase: .instant, timestamp: UInt64(10 + index), arg0: UInt64(100 + index))
            }
        }
        #expect(ring.counters.droppedRecords == 0)
        #expect(ring.records().last?.arg0 == 199)
    }

    @Test func adoptionMovesTheHeapRecordsIntoTheFile() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let ring = TraceRing(records: 4096, role: "app", pid: 4321)
        for index in 0 ..< 50 {
            ring.write(name: 3, phase: .begin, timestamp: UInt64(index), arg0: UInt64(index))
        }
        #expect(!ring.isFileBacked)
        let file = try #require(TraceRingFile.adopt(ring, directory: directory))
        #expect(ring.isFileBacked)
        #expect(file.path == directory + "/app-4321.cmxtrace")
        for index in 50 ..< 100 {
            ring.write(name: 3, phase: .end, timestamp: UInt64(index), arg0: UInt64(index))
        }
        let expected = (0 ..< 100).map(UInt64.init)
        #expect(ring.records().map(\.arg0) == expected)
        #expect(file.records().map(\.arg0) == expected)
        #expect(try #require(TraceRingFile.records(atPath: file.path)).map(\.arg0) == expected)
        #expect(ring.counters.adoptFailures == 0)
    }

    @Test func aFailedAdoptionKeepsTheHeapRingAndCountsIt() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let notADirectory = directory + "/file"
        #expect(FileManager.default.createFile(atPath: notADirectory, contents: Data([1])))
        let ring = TraceRing(records: 4096, role: "app")
        ring.write(name: 1, phase: .instant, timestamp: 1, arg0: 1)
        #expect(TraceRingFile.adopt(ring, directory: notADirectory) == nil)
        #expect(!ring.isFileBacked)
        #expect(ring.counters.adoptFailures == 1)
        ring.write(name: 1, phase: .instant, timestamp: 2, arg0: 2)
        #expect(ring.records().map(\.arg0) == [1, 2])
    }

    /// A spare file left by an earlier run is renamed, and its old contents never decode.
    @Test func adoptionRenamesAndResetsTheSpareFile() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let old = TraceRing(records: 4096, role: "daemon", pid: 1)
        for index in 0 ..< 40 {
            old.write(name: 5, phase: .instant, timestamp: UInt64(index), arg0: 9000 + UInt64(index))
        }
        #expect(TraceRingFile.prepareSpare(directory: directory, role: "daemon", records: 4096))
        let spare = directory + "/" + TraceRingFile.spareName(role: "daemon")
        // The spare holds an old ring, as if an earlier process had recycled its file.
        let handle = try #require(FileHandle(forWritingAtPath: spare))
        try handle.write(contentsOf: Data(old.image()))
        try handle.close()
        #expect(try #require(TraceRingFile.records(atPath: spare)).count == 40)

        let ring = TraceRing(records: 4096, role: "daemon", pid: 2)
        ring.write(name: 6, phase: .instant, timestamp: 1, arg0: 1)
        let file = try #require(TraceRingFile.adopt(ring, directory: directory))
        #expect(!FileManager.default.fileExists(atPath: spare))
        #expect(try #require(TraceRingFile.records(atPath: file.path)).map(\.arg0) == [1])
    }

    /// A child that aborts right after writing leaves a file whose records all decode.
    @Test func anAbortedChildLeavesADecodableFile() async throws {
        let directory = TraceRingChild.directory(parent: getpid())
        defer { try? FileManager.default.removeItem(atPath: directory) }
        await #expect(processExitsWith: .signal(SIGABRT)) {
            TraceRingChild.writeThenAbort()
        }
        let files = try FileManager.default.contentsOfDirectory(atPath: directory).filter { $0.hasSuffix(".cmxtrace") }
        #expect(files.count == 1)
        let path = directory + "/" + (files.first ?? "")
        let records = try #require(TraceRingFile.records(atPath: path), "the aborted child's ring did not decode")
        #expect(records.map(\.arg0) == (0 ..< TraceRingChild.records).map(UInt64.init))
    }

    /// Per-thread chunks keep writers apart: the p99 of a 31-record batch with 8 threads writing at once
    /// stays within 20% of one thread alone. Optimized builds only (-c release; Debug timing says
    /// nothing); needs 9 cores.
    @Test func eightContendedThreadsKeepTheSingleThreadP99() {
        guard !_isDebugAssertConfiguration(), ProcessInfo.processInfo.activeProcessorCount >= 9 else { return }
        let single = (0 ..< 3).map { _ in Self.batchP99(threads: 1) }.min() ?? 0
        let contended = (0 ..< 3).map { _ in Self.batchP99(threads: 8) }.min() ?? 0
        #expect(Double(contended) <= Double(single) * 1.2,
                "8-thread batch p99 \(contended) ns, single-thread \(single) ns")
    }

    /// The highest per-thread p99 of a 31-record batch (one chunk claim and 31 writes), in nanoseconds.
    private static func batchP99(threads: Int) -> UInt64 {
        let batches = 4000
        let ring = TraceRing(records: threads * (batches + 2) * TraceRing.recordsPerChunk, role: "bench")
        let worst = SharedCount()
        let ready = SharedCount()
        runOnThreads(threads) { _ in
            var local = [UInt64](repeating: 0, count: batches)
            ready.value.add(1, ordering: .acquiringAndReleasing)
            while ready.value.load(ordering: .acquiring) < threads {}
            for batch in 0 ..< batches {
                let start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
                for index in 0 ..< TraceRing.recordsPerChunk {
                    ring.write(name: 1, phase: .instant, timestamp: start, arg0: UInt64(index))
                }
                local[batch] = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - start
            }
            local.sort()
            let p99 = Int(local[batches * 99 / 100])
            var seen = worst.value.load(ordering: .relaxed)
            while seen < p99 {
                let swapped = worst.value.compareExchange(expected: seen, desired: p99, ordering: .relaxed)
                if swapped.exchanged { break }
                seen = swapped.original
            }
        }
        return UInt64(worst.value.load(ordering: .relaxed))
    }

    // MARK: - Helpers

    /// Writes a record whose fields all derive from `value`, so a torn record shows.
    private static func writeChecked(_ ring: TraceRing, value: UInt64) {
        ring.write(name: UInt16(truncatingIfNeeded: value), phase: .counter, flags: UInt8(truncatingIfNeeded: value >> 32),
                   timestamp: value &* 3 &+ 7, arg0: value, arg1: value &* 0x9E37_79B9_7F4A_7C15)
    }

    private static func isWhole(_ record: TraceRecord) -> Bool {
        let value = record.arg0
        return record.name == UInt16(truncatingIfNeeded: value) && record.phase == .counter
            && record.flags == UInt8(truncatingIfNeeded: value >> 32) && record.timestamp == value &* 3 &+ 7
            && record.arg1 == value &* 0x9E37_79B9_7F4A_7C15
    }

    private func temporaryDirectory() throws -> String {
        let path = NSTemporaryDirectory() + "cmux-trace-ring-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }
}

/// The exit test's child: it writes on the heap, adopts a file, writes there, and aborts.
enum TraceRingChild {
    static let records = 1000

    static func directory(parent: pid_t) -> String {
        NSTemporaryDirectory() + "cmux-trace-ring-abort-\(parent)"
    }

    static func writeThenAbort() {
        let ring = TraceRing(records: 4096, role: "child")
        for index in 0 ..< records / 2 {
            ring.write(name: 1, phase: .instant, timestamp: UInt64(index), arg0: UInt64(index))
        }
        guard TraceRingFile.adopt(ring, directory: directory(parent: getppid())) != nil else { exit(3) }
        for index in records / 2 ..< records {
            ring.write(name: 1, phase: .instant, timestamp: UInt64(index), arg0: UInt64(index))
        }
        abort()
    }
}

/// Runs `body(index)` on `count` new threads at once and returns when all have exited (so their
/// thread-exit destructors ran).
private func runOnThreads(_ count: Int, _ body: @escaping @Sendable (Int) -> Void) {
    var threads: [pthread_t] = []
    for index in 0 ..< count {
        let context = Unmanaged.passRetained(ThreadBody { body(index) }).toOpaque()
        var thread: pthread_t?
        let created = pthread_create(&thread, nil, { context in
            Unmanaged<ThreadBody>.fromOpaque(context).takeRetainedValue().run()
            return nil
        }, context)
        if created == 0, let thread {
            threads.append(thread)
        } else {
            Unmanaged<ThreadBody>.fromOpaque(context).release()
            Issue.record("pthread_create failed: \(created)")
        }
    }
    for thread in threads {
        pthread_join(thread, nil)
    }
}

private final class ThreadBody: Sendable {
    let run: @Sendable () -> Void

    init(_ run: @escaping @Sendable () -> Void) {
        self.run = run
    }
}

/// A count the test's threads share.
private final class SharedCount: Sendable {
    let value = Atomic<Int>(0)
}
