import CmuxNextCompat
import CmuxNextTrace
import Darwin
import Foundation
import Testing

/// The trace ring v1 tests, one serialized suite: the 8-thread tests and the
/// contention measurement must not share the machine with each other. `--filter TraceRingTests` runs all.
@Suite(.serialized)
enum TraceRingTests {}

extension TraceRingTests {
    /// The ring's bytes (the trace.md layout and the golden file the Rust crate shares), per-thread chunks,
    /// the seqlock publish, black-box overwrite and the bounded claim.
    @Suite struct Ring {
        // MARK: - The trace.md bytes

        /// The Swift writer builds the golden ring of `cmux-trace`'s `golden_bytes()` (tests/ring.rs) and
        /// produces the shared fixture byte for byte.
        @Test func theGoldenRingIsByteIdenticalToTheSharedFixture() throws {
            let golden = try Self.goldenFixture()
            let bytes = Self.goldenRing().image()
            #expect(bytes.count == golden.count)
            let first = bytes.indices.first { $0 < golden.count && bytes[$0] != golden[$0] }
            #expect(first == nil, "ring v1 bytes differ from the shared golden file at offset \(first ?? -1)")
        }

        /// The fixture the Rust writer made decodes in Swift: the records, phases and flags of the recipe.
        @Test func theGoldenFixtureDecodes() throws {
            let records = try #require(TraceRing.records(inImage: Self.goldenFixture()))
            #expect(records.count == 38)
            let phases = records.prefix(8).map { [$0.timestamp, UInt64($0.phaseCode), UInt64($0.flags)] }
            #expect(phases == [[1000, 0x42, 0], [1050, 0x62, 1], [1100, 0x73, 0], [1150, 0x66, 0],
                               [1200, 0x45, 0], [1300, 0x65, 1], [1350, 0x43, 3], [1375, 0x49, 0]])
            #expect(records.allSatisfy { $0.phase != nil })
            let interned = try #require(records.first { $0.timestamp == 1375 })
            #expect(interned.name == 4)
            #expect(interned.threadIndex == 1)
            #expect(records.filter { $0.threadIndex == 0 }.map(\.timestamp).last == 1429)
        }

        @Test func aWrittenRecordDecodesWithEveryField() {
            let ring = TraceRing(records: 4096, role: .app)
            for index in 0 ..< 100 {
                ring.write(name: UInt16(index), phase: .asyncBegin, flags: 1, timestamp: 1000 + UInt64(index),
                           arg0: UInt64(index), arg1: ~UInt64(index))
            }
            let records = ring.records()
            #expect(records.map(\.arg0) == (0 ..< 100).map(UInt64.init))
            let last = records.last
            #expect(last?.name == 99)
            #expect(last?.phase == .asyncBegin)
            #expect(last?.phaseCode == 0x62)
            #expect(last?.flags == 1)
            #expect(last?.timestamp == 1099)
            #expect(last?.arg1 == ~UInt64(99))
            #expect(Set(records.map(\.threadIndex)) == [0])
            let counters = ring.counters
            #expect([counters.chunksOverwritten, counters.chunksSkipped, counters.recordsDropped, counters.adoptFailures] == [0, 0, 0, 0])
            #expect(TraceRing.records(inImage: ring.image()) == records)
        }

        @Test func eightThreadsDecodeExactlyOnceInPerThreadOrder() {
            let perThread = 100_000
            let ring = TraceRing(records: 8 * perThread + 8 * 2 * TraceRing.recordsPerChunk, role: .app)
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
            #expect(ring.counters.recordsDropped == 0)
            #expect(ring.counters.chunksOverwritten == 0)
        }

        /// Writers overwrite a small ring while a reader decodes it, live and through an image: every record
        /// the reader accepts is whole.
        @Test func aReaderNeverAcceptsATornRecord() {
            let ring = TraceRing(records: 16 * TraceRing.recordsPerChunk, role: .app)
            let writersDone = SharedCount()
            let reads = SharedCount()
            let tornLive = SharedCount()
            let tornImage = SharedCount()
            runOnThreads(5) { tag in
                if tag == 4 {
                    while writersDone.value.load(ordering: .acquiring) < 4 {
                        tornLive.value.add(ring.records().filter { !TraceRingCheck.isWhole($0) }.count, ordering: .relaxed)
                        let imaged = TraceRing.records(inImage: ring.image()) ?? []
                        tornImage.value.add(imaged.filter { !TraceRingCheck.isWhole($0) }.count, ordering: .relaxed)
                        reads.value.add(1, ordering: .relaxed)
                    }
                    return
                }
                for index in 0 ..< 300_000 {
                    TraceRingCheck.writeChecked(ring, value: UInt64(tag) << 32 | UInt64(index))
                }
                writersDone.value.add(1, ordering: .releasing)
            }
            #expect(reads.value.load(ordering: .relaxed) > 0)
            #expect(tornLive.value.load(ordering: .relaxed) == 0, "the live decoder accepted torn records")
            #expect(tornImage.value.load(ordering: .relaxed) == 0, "an image held torn records")
            #expect(ring.records().allSatisfy(TraceRingCheck.isWhole))
        }

        /// A crash mid-write leaves an odd sequence; an old lap's record, a chunk never claimed, a chunk of an
        /// earlier recording and a record before the ring's start are stale. The decoder accepts none of them.
        @Test func theDecoderSkipsUnpublishedAndStaleSlots() throws {
            let ring = TraceRing(records: 4096, role: .app)
            for index in 0 ..< 4 {
                ring.write(name: 1, phase: .instant, timestamp: 10 + UInt64(index), arg0: UInt64(index))
            }
            let image = ring.image()
            // The thread's first chunk is chunk 0 (ticket 0, lap 0), whose published sequence is 2.
            let chunks = Int(TraceRingCheck.u64(image, 120))
            func sequenceByte(slot: Int) -> Int { chunks + slot * TraceRing.recordBytes + 8 }
            #expect(try #require(TraceRing.records(inImage: image)).map(\.arg0) == [0, 1, 2, 3])

            var writing = image
            writing[sequenceByte(slot: 2)] = 1 // odd: the writer stopped inside this record
            #expect(try #require(TraceRing.records(inImage: writing)).map(\.arg0) == [0, 2, 3])

            var oldLap = image
            oldLap[sequenceByte(slot: 3)] = 4 // lap 1's sequence in a lap-0 chunk
            #expect(try #require(TraceRing.records(inImage: oldLap)).map(\.arg0) == [0, 1, 3])

            var unclaimed = image
            unclaimed[chunks + 8] = 0 // lap_seq 0: never claimed
            #expect(try #require(TraceRing.records(inImage: unclaimed)).isEmpty)

            var laterRecording = image
            TraceRingCheck.put(&laterRecording, 224, TraceRingCheck.u64(image, 112) >> 32) // recording_start_cursor: lap 1
            #expect(try #require(TraceRing.records(inImage: laterRecording)).isEmpty)

            var laterStart = image
            TraceRingCheck.put(&laterStart, 24, 12) // start_uptime_ns after the first two records
            #expect(try #require(TraceRing.records(inImage: laterStart)).map(\.arg0) == [2, 3])

            var notARing = image
            notARing[0] = 0
            #expect(TraceRing.records(inImage: notARing) == nil)
            var oddCount = image
            TraceRingCheck.put(&oddCount, 112, UInt64(TraceRing.chunkBytes) | 3 << 32) // chunk_count 3: not a power of two
            #expect(TraceRing.records(inImage: oddCount) == nil)
            #expect(TraceRing.records(inImage: Array(image.prefix(chunks + 10))) == nil)
        }

        // MARK: - Claims and overwrite

        /// The black box: after 10x its capacity only whole records remain, in per-thread order, with every
        /// thread's newest record. Each thread holds its last chunk until all have finished, so no released
        /// chunk is overwritten after its thread's last write.
        @Test func afterTenTimesCapacityOnlyWholeRecordsDecode() {
            let ring = TraceRing(records: 4096, role: .app)
            let perThread = ring.capacity * 10 / 4
            let finished = SharedCount()
            runOnThreads(4) { tag in
                for index in 0 ..< perThread {
                    TraceRingCheck.writeChecked(ring, value: UInt64(tag) << 32 | UInt64(index))
                }
                finished.value.add(1, ordering: .acquiringAndReleasing)
                while finished.value.load(ordering: .acquiring) < 4 {}
            }
            let records = ring.records()
            #expect(records.allSatisfy(TraceRingCheck.isWhole))
            #expect(records.count <= ring.capacity)
            #expect(records.count >= ring.capacity - 4 * TraceRing.recordsPerChunk)
            #expect(ring.counters.chunksOverwritten > 0)
            for tag in 0 ..< 4 {
                let values = records.filter { $0.arg0 >> 32 == UInt64(tag) }.map { $0.arg0 & 0xFFFF_FFFF }
                #expect(values.last == UInt64(perThread - 1), "thread \(tag)'s newest record was lost")
                #expect(zip(values, values.dropFirst()).allSatisfy { $0 < $1 }, "thread \(tag)'s records are out of order")
            }
        }

        /// A live thread's chunk is never overwritten, however far the others wrap.
        @Test func aLiveThreadsChunkIsNeverOverwritten() {
            let ring = TraceRing(records: 4 * TraceRing.recordsPerChunk, role: .app)
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
            #expect(ring.counters.chunksSkipped > 0)
        }

        /// With every chunk owned by a live thread, a write makes exactly four claim tries, then drops the
        /// record and counts it: the cursor moves by four, not a lap.
        @Test func aClaimGivesUpAfterFourTries() {
            let ring = TraceRing(sizes: TraceRing.Sizes(nameCapacity: 16, threadCapacity: 256, chunkCount: 4),
                                 identity: TraceRing.Identity(pid: 1, role: .app))
            let holding = SharedCount()
            let release = SharedCount()
            let cursorAfter = SharedCount()
            runOnThreads(5) { tag in
                if tag < 4 {
                    ring.write(name: 1, phase: .instant, timestamp: 1, arg0: UInt64(tag))
                    holding.value.add(1, ordering: .acquiringAndReleasing)
                    while release.value.load(ordering: .acquiring) == 0 {}
                    return
                }
                while holding.value.load(ordering: .acquiring) < 4 {}
                ring.write(name: 2, phase: .instant, timestamp: 2, arg0: 99)
                cursorAfter.value.store(Int(TraceRingCheck.u64(ring.image(), 128)), ordering: .relaxed)
                release.value.store(1, ordering: .releasing)
            }
            #expect(cursorAfter.value.load(ordering: .relaxed) == 8, "four claims, then exactly four tries")
            #expect(ring.counters.recordsDropped == 1)
            #expect(ring.counters.chunksSkipped == 4)
            #expect(!ring.records().contains { $0.arg0 == 99 })
        }

        /// A thread that exits completes its chunk and frees its thread entry: with both chunks once owned by
        /// exited threads, a third thread still finds room.
        @Test func anExitedThreadGivesItsChunkAndEntryBack() {
            let ring = TraceRing(sizes: TraceRing.Sizes(nameCapacity: 16, threadCapacity: 256, chunkCount: 2),
                                 identity: TraceRing.Identity(pid: 1, role: .app))
            runOnThreads(2) { tag in
                ring.write(name: 1, phase: .instant, timestamp: UInt64(tag), arg0: UInt64(tag))
            }
            runOnThreads(1) { _ in
                for index in 0 ..< 100 {
                    ring.write(name: 2, phase: .instant, timestamp: UInt64(10 + index), arg0: UInt64(100 + index))
                }
            }
            #expect(ring.counters.recordsDropped == 0)
            #expect(ring.records().last?.arg0 == 199)
            let image = ring.image()
            #expect(TraceRingCheck.u64(image, 160) >> 32 == 3, "three fresh thread entries")
            let threadTable = Int(TraceRingCheck.u64(image, 152))
            #expect((0 ..< 3).allSatisfy { TraceRingCheck.u64(image, threadTable + $0 * TraceRing.entryBytes) & 0xFFFF_FFFF == 3 },
                    "every exited thread's entry is marked exited")
        }

        // MARK: - Contention

        /// Per-thread chunks keep writers apart: the p99 of a 31-record batch with 8 threads writing at once
        /// stays within 20% of one thread alone. Optimized builds on 9 or more cores only (Debug timing says
        /// nothing); elsewhere the test shows as skipped.
        @Test(.enabled(if: !_isDebugAssertConfiguration() && ProcessInfo.processInfo.activeProcessorCount >= 9,
                       "needs an optimized build (-c release) and 9 cores"))
        func eightContendedThreadsKeepTheSingleThreadP99() {
            let single = (0 ..< 3).map { _ in Self.batchP99(threads: 1) }.min() ?? 0
            let contended = (0 ..< 3).map { _ in Self.batchP99(threads: 8) }.min() ?? 0
            print("trace ring batch p99: single \(single) ns, 8 threads \(contended) ns")
            #expect(Double(contended) <= Double(single) * 1.2,
                    "8-thread batch p99 \(contended) ns, single-thread \(single) ns")
        }

        /// The highest per-thread p99 of a 31-record batch (one chunk claim and 31 writes), in nanoseconds.
        private static func batchP99(threads: Int) -> UInt64 {
            let batches = 4000
            let ring = TraceRing(records: threads * (batches + 2) * TraceRing.recordsPerChunk, role: .app)
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

        /// `cmux-trace`'s golden recipe (tests/ring.rs, `golden_bytes`): a daemon ring with 64 names, 256
        /// threads and 4 chunks, three catalog entries, thread "main" (tid 101) writing 33 records and thread
        /// "cmux-io" (tid 202) writing 5 (one under the interned name "cmux.io.read"), then both exiting.
        private static func goldenRing() -> TraceRing {
            var bootSession: [UInt8] = []
            var build: [UInt8] = []
            for index in 0 ..< 16 {
                bootSession.append(0x10 + UInt8(index))
                build.append(0x20 + UInt8(index))
            }
            let identity = TraceRing.Identity(
                pid: 4242, role: .daemon, ringKind: 1, clockDomain: 1, startUptimeNanos: 1000,
                startUnixNanos: 1_700_000_000_000_000_000, startContinuousNanos: 2000,
                processStartUnixMicros: 1_699_999_999_000_000, bootSessionUUID: bootSession, buildUUID: build,
                buildVersion: "1.2.3 (45) abcdef0", categories: 0x1FF
            )
            let catalog = [
                TraceRing.CatalogName(id: 1, kind: 1, category: 1, text: "key.frame"),
                TraceRing.CatalogName(id: 2, kind: 1, category: 6, text: "daemon.request"),
                TraceRing.CatalogName(id: 3, kind: 3, category: 1, text: "key"),
            ]
            let ring = TraceRing(sizes: TraceRing.Sizes(nameCapacity: 64, threadCapacity: 256, chunkCount: 4),
                                 identity: identity, catalog: catalog) {
                TraceRing.ThreadIdentity.current().name == "main"
                    ? TraceRing.ThreadIdentity(tid: 101, qos: 0x21, name: "main")
                    : TraceRing.ThreadIdentity(tid: 202, qos: 0x19, name: "cmux-io")
            }
            let stage = SharedCount()
            runOnThreads(2) { tag in
                if tag == 0 {
                    pthread_setname_np("main")
                    ring.write(name: 1, phase: .begin, timestamp: 1000, arg0: 7)
                    stage.value.store(1, ordering: .releasing)
                    while stage.value.load(ordering: .acquiring) < 2 {}
                    ring.write(name: 1, phase: .flowOut, timestamp: 1100, arg1: 99)
                    ring.write(name: 1, phase: .end, timestamp: 1200)
                    for index in 0 ..< 30 {
                        ring.write(name: 1, phase: .instant, timestamp: 1400 + UInt64(index), arg0: UInt64(index), arg1: 4)
                    }
                } else {
                    pthread_setname_np("cmux-io")
                    while stage.value.load(ordering: .acquiring) < 1 {}
                    ring.write(name: 2, phase: .asyncBegin, flags: 1, timestamp: 1050, arg1: 5)
                    ring.write(name: 2, phase: .flowIn, timestamp: 1150, arg1: 99)
                    ring.write(name: 2, phase: .asyncEnd, flags: 1, timestamp: 1300, arg1: 5)
                    ring.write(name: 2, phase: .counter, flags: 3, timestamp: 1350, arg0: 42, arg1: 3)
                    let read = ring.intern("cmux.io.read", category: 6)
                    ring.write(name: read, phase: .instant, timestamp: 1375, arg0: 8)
                    stage.value.store(2, ordering: .releasing)
                }
            }
            return ring
        }

        private static func goldenFixture() throws -> [UInt8] {
            let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .appendingPathComponent("Fixtures/ring-v1-golden.cmxtrace")
            return try [UInt8](Data(contentsOf: url))
        }
    }
}

