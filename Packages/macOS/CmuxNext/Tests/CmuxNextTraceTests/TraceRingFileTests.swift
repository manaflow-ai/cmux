import CmuxNextCompat
import CmuxNextTrace
import Darwin
import Foundation
import Testing

extension TraceRingTests {
    /// Heap, then file: copy-then-swap adoption, the one-shot rule, the spare file, decoding a file by path
    /// while it is written, and a crashed writer's file.
    @Suite struct File {
        @Test func adoptionMovesTheHeapRecordsIntoTheFile() throws {
            let directory = try TraceRingCheck.temporaryDirectory()
            defer { try? FileManager.default.removeItem(atPath: directory) }
            let ring = TraceRing(records: 4096, role: .app, pid: 4321)
            for index in 0 ..< 50 {
                ring.write(name: 3, phase: .begin, timestamp: UInt64(index), arg0: UInt64(index))
            }
            #expect(!ring.isFileBacked)
            let file = try #require(TraceRingFile.adopt(ring, directory: directory))
            #expect(ring.isFileBacked)
            #expect(file.path == directory + "/app-4321.blackbox.cmxtrace")
            for index in 50 ..< 100 {
                ring.write(name: 3, phase: .end, timestamp: UInt64(index), arg0: UInt64(index))
            }
            let expected = (0 ..< 100).map(UInt64.init)
            #expect(ring.records().map(\.arg0) == expected)
            #expect(file.records().map(\.arg0) == expected)
            #expect(try #require(TraceRingFile.records(atPath: file.path)).map(\.arg0) == expected)
            let image = ring.image()
            let chunkCount = TraceRingCheck.u64(image, 112) >> 32
            #expect(TraceRingCheck.u64(image, 200) == 2, "heap_cursor: the heap claimed two chunks")
            #expect(TraceRingCheck.u64(image, 128) == 2 + chunkCount + 2, "the file's claims start a lap past the copied ones")
            #expect(ring.counters.adoptFailures == 0)
            #expect(ring.counters.heapChunksLost == 0)
        }

        /// Adoption is one-shot: a second call is refused and counted, and the file keeps its records.
        @Test func aSecondAdoptionIsRefused() throws {
            let directory = try TraceRingCheck.temporaryDirectory()
            defer { try? FileManager.default.removeItem(atPath: directory) }
            let ring = TraceRing(records: 4096, role: .daemon, pid: 77)
            ring.write(name: 1, phase: .instant, timestamp: 1, arg0: 1)
            let file = try #require(TraceRingFile.adopt(ring, directory: directory))
            ring.write(name: 1, phase: .instant, timestamp: 2, arg0: 2)
            #expect(TraceRingFile.adopt(ring, directory: directory) == nil)
            #expect(ring.counters.adoptFailures == 1)
            ring.write(name: 1, phase: .instant, timestamp: 3, arg0: 3)
            #expect(try #require(TraceRingFile.records(atPath: file.path)).map(\.arg0) == [1, 2, 3])
        }

        /// The heap is full and eight threads write through the adoption. The copy goes first and the file's
        /// cursor starts a lap past it, so every record a thread writes into the file survives, in order and
        /// after its copied heap records: no copied chunk overwrites a newer one.
        @Test func adoptionWhileEightThreadsWriteKeepsEveryRecordWrittenToTheFile() throws {
            let directory = try TraceRingCheck.temporaryDirectory()
            defer { try? FileManager.default.removeItem(atPath: directory) }
            let ring = TraceRing(records: 32 * 1024, role: .app, pid: 9)
            for index in 0 ..< 2 * ring.capacity {
                ring.write(name: 1, phase: .instant, timestamp: clock_gettime_nsec_np(CLOCK_UPTIME_RAW), arg0: 99 << 32 | UInt64(index))
            }
            let adopted = SharedCount()
            let started = SharedCount()
            let finished = SharedCount()
            let lastValues = (0 ..< 8).map { _ in SharedCount() }
            runOnThreads(9) { tag in
                if tag == 8 {
                    while started.value.load(ordering: .acquiring) < 8 {}
                    let file = TraceRingFile.adopt(ring, directory: directory)
                    adopted.value.store(file == nil ? 2 : 1, ordering: .releasing)
                    return
                }
                started.value.add(1, ordering: .acquiringAndReleasing)
                var index = 0
                var after = 0
                while after < 100 {
                    if adopted.value.load(ordering: .acquiring) != 0 { after += 1 }
                    ring.write(name: 2, phase: .instant, timestamp: clock_gettime_nsec_np(CLOCK_UPTIME_RAW),
                               arg0: UInt64(tag) << 32 | UInt64(index))
                    index += 1
                    sched_yield()
                }
                lastValues[tag].value.store(index - 1, ordering: .relaxed)
                finished.value.add(1, ordering: .acquiringAndReleasing)
                while finished.value.load(ordering: .acquiring) < 8 {}
            }
            #expect(adopted.value.load(ordering: .relaxed) == 1)
            let path = directory + "/" + TraceRingFile.fileName(role: .app, pid: 9)
            let records = try #require(TraceRingFile.records(atPath: path))
            let image = ring.image()
            let firstFileTicket = TraceRingCheck.u64(image, 200) + (TraceRingCheck.u64(image, 112) >> 32)
            // The writers wrap the full heap before the adoption runs, so the copied chunks hold their records.
            #expect(records.contains { $0.ticket < firstFileTicket }, "the copied heap records are in the file")
            for tag in 0 ..< 8 {
                let mine = records.filter { $0.arg0 >> 32 == UInt64(tag) }
                let values = mine.map { $0.arg0 & 0xFFFF_FFFF }
                #expect(zip(values, values.dropFirst()).allSatisfy { $0 < $1 }, "thread \(tag)'s records are out of order")
                let inFile = mine.filter { $0.ticket >= firstFileTicket }.map { $0.arg0 & 0xFFFF_FFFF }
                let copied = mine.filter { $0.ticket < firstFileTicket }.map { $0.arg0 & 0xFFFF_FFFF }
                #expect(inFile.count >= 100, "thread \(tag) lost records it wrote into the file")
                #expect(inFile.last == UInt64(lastValues[tag].value.load(ordering: .relaxed)), "thread \(tag)'s newest record was lost")
                #expect(zip(inFile, inFile.dropFirst()).allSatisfy { $1 == $0 + 1 }, "thread \(tag) has a gap in the file")
                #expect((copied.last ?? 0) < (inFile.first ?? 1), "a copied heap record is newer than a file record")
            }
        }

        @Test func aFailedAdoptionKeepsTheHeapRingAndCountsIt() throws {
            let directory = try TraceRingCheck.temporaryDirectory()
            defer { try? FileManager.default.removeItem(atPath: directory) }
            let notADirectory = directory + "/file"
            #expect(FileManager.default.createFile(atPath: notADirectory, contents: Data([1])))
            let ring = TraceRing(records: 4096, role: .app)
            ring.write(name: 1, phase: .instant, timestamp: 1, arg0: 1)
            #expect(TraceRingFile.adopt(ring, directory: notADirectory) == nil)
            #expect(!ring.isFileBacked)
            #expect(ring.counters.adoptFailures == 1)
            ring.write(name: 1, phase: .instant, timestamp: 2, arg0: 2)
            #expect(ring.records().map(\.arg0) == [1, 2])
            // A failed adoption may be tried again.
            #expect(TraceRingFile.adopt(ring, directory: directory) != nil)
            #expect(ring.isFileBacked)
        }

        /// A spare file is renamed with its allocated size, and an old ring left in it never decodes.
        @Test func adoptionRenamesAndZeroesTheSpareFile() throws {
            let directory = try TraceRingCheck.temporaryDirectory()
            defer { try? FileManager.default.removeItem(atPath: directory) }
            let sizes = TraceRing.Sizes(records: 4096)
            let old = TraceRing(sizes: sizes, identity: TraceRing.Identity(pid: 1, role: .daemon))
            for index in 0 ..< 40 {
                old.write(name: 5, phase: .instant, timestamp: UInt64(index), arg0: 9000 + UInt64(index))
            }
            #expect(TraceRingFile.prepareSpare(directory: directory, role: .daemon, sizes: sizes))
            let spare = directory + "/" + TraceRingFile.spareName(role: .daemon)
            // The spare holds an old ring, as if an earlier process had recycled its file.
            let handle = try #require(FileHandle(forWritingAtPath: spare))
            try handle.write(contentsOf: Data(old.image()))
            try handle.close()
            #expect(try #require(TraceRingFile.records(atPath: spare)).count == 40)

            let ring = TraceRing(sizes: sizes, identity: TraceRing.Identity(pid: 2, role: .daemon))
            ring.write(name: 6, phase: .instant, timestamp: 1, arg0: 1)
            let file = try #require(TraceRingFile.adopt(ring, directory: directory))
            #expect(!FileManager.default.fileExists(atPath: spare))
            #expect(try #require(TraceRingFile.records(atPath: file.path)).map(\.arg0) == [1])
        }

        /// `records(atPath:)` decodes a file whose process still writes: it reads the mapping with the
        /// seqlock, so it never pairs one record's time with another's sequence.
        @Test func decodingAFileWhileItsWritersWriteAcceptsOnlyWholeRecords() throws {
            let directory = try TraceRingCheck.temporaryDirectory()
            defer { try? FileManager.default.removeItem(atPath: directory) }
            let ring = TraceRing(records: 16 * TraceRing.recordsPerChunk, role: .holder)
            let file = try #require(TraceRingFile.adopt(ring, directory: directory))
            let path = file.path
            let writersDone = SharedCount()
            let reads = SharedCount()
            let torn = SharedCount()
            runOnThreads(5) { tag in
                if tag == 4 {
                    while writersDone.value.load(ordering: .acquiring) < 4 {
                        let decoded = TraceRingFile.records(atPath: path) ?? []
                        torn.value.add(decoded.filter { !TraceRingCheck.isWhole($0) }.count, ordering: .relaxed)
                        reads.value.add(1, ordering: .relaxed)
                    }
                    return
                }
                for index in 0 ..< 200_000 {
                    TraceRingCheck.writeChecked(ring, value: UInt64(tag) << 32 | UInt64(index))
                }
                writersDone.value.add(1, ordering: .releasing)
            }
            #expect(reads.value.load(ordering: .relaxed) > 0)
            #expect(torn.value.load(ordering: .relaxed) == 0, "decoding by path accepted torn records")
        }

        /// A child that aborts right after writing leaves a file whose records all decode.
        @Test func anAbortedChildLeavesADecodableFile() async throws {
            let directory = TraceRingChild.directory(parent: getpid())
            defer { try? FileManager.default.removeItem(atPath: directory) }
            await #expect(processExitsWith: .signal(SIGABRT)) {
                TraceRingChild.writeThenAbort()
            }
            let files = try FileManager.default.contentsOfDirectory(atPath: directory).filter { $0.hasSuffix(".blackbox.cmxtrace") }
            #expect(files.count == 1)
            let path = directory + "/" + (files.first ?? "")
            let records = try #require(TraceRingFile.records(atPath: path), "the aborted child's ring did not decode")
            #expect(records.map(\.arg0) == (0 ..< TraceRingChild.records).map(UInt64.init))
        }
    }
}

/// The exit test's child: it writes on the heap, adopts a file, writes there, and aborts.
enum TraceRingChild {
    static let records = 1000

    static func directory(parent: pid_t) -> String {
        NSTemporaryDirectory() + "cmux-trace-ring-abort-\(parent)"
    }

    static func writeThenAbort() {
        let ring = TraceRing(records: 4096, role: .app)
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
