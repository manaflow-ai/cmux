import CmuxNextCompat
@testable import CmuxNextTrace
import Foundation
import Testing

/// The ring's name table: fixed catalog ids, category entries, names interned once
/// per ring, and decoding every name from the ring's own bytes.
@Suite(.serialized)
struct TraceNamesTests {
    private static let catalog = TraceRing.nameTable(
        names: [(id: 1, category: 0, text: "action.perform"), (id: 2, category: 1, text: "key.frame"),
                (id: 3, category: 6, text: "daemon.request")],
        categories: [(bit: 0, text: "action"), (bit: 1, text: "key"), (bit: 6, text: "daemon")]
    )

    private static func ring(catalog: [TraceRing.CatalogName] = catalog, names: Int = 64, chunks: Int = 64,
                             identity: TraceRing.Identity = TraceRing.Identity(pid: 1, role: .app)) -> TraceRing {
        TraceRing(sizes: TraceRing.Sizes(nameCapacity: names, threadCapacity: 256, chunkCount: chunks), identity: identity,
                  catalog: catalog)
    }

    @Test("The table puts each catalog name at its id, then one entry per category")
    func catalogAndCategoryEntries() throws {
        #expect(Self.catalog.map(\.id) == [1, 2, 3, 4, 5, 10])
        #expect(Self.catalog.map(\.kind) == [1, 1, 1, 3, 3, 3])
        let image = try #require(Self.ring().decodedImage())
        #expect(image.names.map(\.id) == [1, 2, 3, 4, 5, 10])
        #expect(image.names.map(\.text) == ["action.perform", "key.frame", "daemon.request", "action", "key", "daemon"])
        #expect(image.names.map(\.kindCode) == [1, 1, 1, 3, 3, 3])
        #expect(image.names.allSatisfy { $0.kind != nil })
        #expect(image.names.map(\.category) == [0, 1, 6, 0, 1, 6])
        #expect(image.name(0) == nil)
    }

    /// The acceptance case: two builds give the same names other ids. A ring of the other build decodes by
    /// its own table, and reading it with this build's ids would name its records wrong.
    @Test("A ring written with another case order decodes from its own table")
    func anotherCaseOrderDecodes() throws {
        let otherBuild = TraceRing.nameTable(
            names: [(id: 3, category: 0, text: "action.perform"), (id: 1, category: 1, text: "key.frame"),
                    (id: 2, category: 6, text: "daemon.request")],
            categories: [(bit: 0, text: "action"), (bit: 1, text: "key"), (bit: 6, text: "daemon")]
        )
        let ring = Self.ring(catalog: otherBuild)
        let written: [(UInt16, String)] = [(3, "action.perform"), (1, "key.frame"), (2, "daemon.request"), (1, "key.frame")]
        for (index, (id, _)) in written.enumerated() {
            ring.write(name: id, phase: .instant, timestamp: 100 + UInt64(index), arg0: UInt64(index))
        }
        let image = try #require(TraceRing.Image(bytes: ring.image()))
        #expect(image.records.map { image.name(of: $0) } == written.map { $0.1 as String? })
        let thisBuild = Dictionary(uniqueKeysWithValues: Self.catalog.map { ($0.id, $0) })
        let misread = image.records.filter { record in
            thisBuild[record.name].map { String(describing: $0.text) } != image.name(of: record)
        }
        #expect(misread.count == written.count, "the two builds' ids must differ for this test to mean anything")
    }

    @Test("An interned name takes one entry per ring, then one load per record")
    func internedOncePerRing() throws {
        let ring = Self.ring()
        let name = TraceRuntime.InternedName("cmux.io.read", categoryBit: 6)
        for index in 0 ..< 1000 {
            ring.write(name, phase: .instant, timestamp: UInt64(index), arg0: UInt64(index))
        }
        let image = try #require(ring.decodedImage())
        let entries = image.names.filter { $0.text == "cmux.io.read" }
        #expect(entries.count == 1)
        let entry = try #require(entries.first)
        #expect(entry.id == 11, "interned names follow the catalog and category entries")
        #expect(entry.kind == TraceRing.NameEntry.Kind.interned)
        #expect(entry.category == 6)
        #expect(name.cachedID(inSlot: 0) == entry.id, "slot 0 (the heap) keeps the id")
        #expect(image.records.count == 1000)
        #expect(image.records.allSatisfy { $0.name == entry.id })
    }

    @Test("Threads interning one name at once all write the id that won")
    func concurrentFirstUse() throws {
        let ring = Self.ring(chunks: 256)
        let name = TraceRuntime.InternedName("task.post.here", categoryBit: 12)
        let threads = 8
        let ready = SharedCount()
        runOnThreads(threads) { tag in
            ready.value.add(1, ordering: .acquiringAndReleasing)
            while ready.value.load(ordering: .acquiring) < threads {}
            for index in 0 ..< 100 {
                ring.write(name, phase: .instant, timestamp: UInt64(index), arg0: UInt64(tag) << 32 | UInt64(index))
            }
        }
        let image = try #require(ring.decodedImage())
        #expect(image.records.count == threads * 100)
        let ids = Set(image.records.map(\.name))
        #expect(ids.count == 1)
        #expect(ids.first == name.cachedID(inSlot: 0))
        #expect(image.records.allSatisfy { image.name(of: $0) == "task.post.here" })
        #expect((1 ... threads).contains(image.names.filter { $0.text == "task.post.here" }.count))
    }

    @Test("A full table writes name 0, counts it and caches nothing")
    func fullTable() throws {
        let catalog = TraceRing.nameTable(names: [(id: 1, category: 0, text: "action.perform")], categories: [])
        let ring = Self.ring(catalog: catalog, names: 3)
        let fits = TraceRuntime.InternedName("fits.here", categoryBit: 0)
        let overflows = TraceRuntime.InternedName("does.not.fit", categoryBit: 0)
        ring.write(fits, phase: .instant, timestamp: 1)
        ring.write(overflows, phase: .instant, timestamp: 2)
        ring.write(overflows, phase: .instant, timestamp: 3)
        let image = try #require(ring.decodedImage())
        #expect(image.records.map { image.name(of: $0) } == ["fits.here", nil, nil])
        #expect(image.records.map(\.name) == [2, 0, 0])
        #expect(image.header.nameOverflow == 2, "each record that found the table full tried again and was counted")
        #expect(overflows.cachedID(inSlot: 0) == 0)
    }

    /// The race the one active-ring load closes: names interned in the heap after the file's copy and before
    /// the swap. Each write uses a new name, so many first interns fall in that window; a heap id written
    /// into a file chunk would name another thread's text there, or nothing.
    @Test("While the file is adopted, every record in it names its writer's text")
    func internedWritesRacingAdoption() throws {
        let directory = try TraceRingCheck.temporaryDirectory()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let texts: [StaticString] = ["adopt.race.0", "adopt.race.1", "adopt.race.2", "adopt.race.3",
                                     "adopt.race.4", "adopt.race.5", "adopt.race.6", "adopt.race.7"]
        let ring = TraceRing(sizes: TraceRing.Sizes(nameCapacity: 16384, threadCapacity: 256, chunkCount: 1024),
                             identity: TraceRing.Identity(pid: 4141, role: .app))
        let started = SharedCount()
        let adopted = SharedCount()
        runOnThreads(texts.count + 1) { tag in
            guard tag < texts.count else {
                while started.value.load(ordering: .acquiring) < texts.count {}
                adopted.value.store(TraceRingFile.adopt(ring, directory: directory) == nil ? 2 : 1, ordering: .releasing)
                return
            }
            started.value.add(1, ordering: .acquiringAndReleasing)
            var after = 0
            for index in 0 ..< 1500 where after < 100 {
                if adopted.value.load(ordering: .acquiring) != 0 { after += 1 }
                ring.write(TraceRuntime.InternedName(texts[tag], categoryBit: 0), phase: .instant,
                           timestamp: UInt64(index + 1), arg0: UInt64(tag))
            }
        }
        #expect(adopted.value.load(ordering: .relaxed) == 1)
        let path = directory + "/" + TraceRingFile.fileName(role: .app, pid: 4141)
        let bytes = try #require(FileManager.default.contents(atPath: path))
        let image = try #require(TraceRing.Image(bytes: [UInt8](bytes)))
        #expect(!image.records.isEmpty)
        let wrong = image.records.filter { image.name(of: $0) != "\(texts[Int($0.arg0)])" }
        #expect(wrong.isEmpty, "\(wrong.count) of \(image.records.count) records name another text or none")
        #expect(image.header.nameOverflow == 0)
    }

    /// Two rings in one slot (two runtimes of one process, as tests make, or one recording ring after another
    /// in slot 2) never share a name's id: each ring interns the name itself, also when the rings take turns.
    @Test("A second ring in the same slot interns the name again and never uses the first ring's id")
    func secondRingInTheSameSlot() throws {
        let first = Self.ring()
        let other = TraceRing.nameTable(names: [(id: 1, category: 0, text: "action.perform"), (id: 2, category: 1, text: "key.frame"),
                                                (id: 3, category: 6, text: "daemon.request"), (id: 4, category: 6, text: "daemon.reply")],
                                        categories: [(bit: 0, text: "action")])
        let second = Self.ring(catalog: other)
        let name = TraceRuntime.InternedName("cmux.io.read", categoryBit: 6)
        for (index, ring) in [first, second, first, second, first].enumerated() {
            ring.write(name, phase: .instant, timestamp: UInt64(index + 1), arg0: UInt64(index))
        }
        for ring in [first, second] {
            let image = try #require(ring.decodedImage())
            #expect(!image.records.isEmpty)
            #expect(image.records.allSatisfy { image.name(of: $0) == "cmux.io.read" },
                    "\(image.records.map { image.name(of: $0) ?? "<none>" })")
        }
    }

    /// `decodedImage()` on a live ring: a thread's entry and its interned name are published before its first
    /// record, so an image that holds the record also holds both (the copy reads the chunks first). Short-lived
    /// threads take exited entries again, so a table read before the records would show an older generation.
    @Test("A live image names every record's name and thread while new threads write")
    func liveImageNamesEveryRecord() throws {
        let writers = 8
        let batches = 50
        let ring = Self.ring(names: 512, chunks: 256)
        let names = (0 ..< writers * batches).map { _ in TraceRuntime.InternedName("live.thread.first", categoryBit: 0) }
        let done = SharedCount()
        let checked = SharedCount()
        let lacking = SharedCount()
        runOnThreads(writers + 1) { tag in
            guard tag < writers else {
                while done.value.load(ordering: .acquiring) < writers {
                    guard let image = ring.decodedImage() else { continue }
                    let generations = Dictionary(image.threads.map { ($0.index, $0.generation) }, uniquingKeysWith: { Swift.max($0, $1) })
                    let missing = image.records.filter { record in
                        guard image.name(of: record) != nil, let generation = generations[record.threadIndex] else { return true }
                        return generation < record.threadGeneration
                    }
                    lacking.value.add(missing.count, ordering: .relaxed)
                    checked.value.add(1, ordering: .relaxed)
                }
                return
            }
            for batch in 0 ..< batches {
                runOnThreads(1) { _ in
                    for index in 0 ..< 8 {
                        ring.write(names[tag * batches + batch], phase: .instant, timestamp: UInt64(batch * 8 + index + 1),
                                   arg0: UInt64(tag))
                    }
                }
            }
            done.value.add(1, ordering: .releasing)
        }
        #expect(checked.value.load(ordering: .relaxed) > 0)
        #expect(lacking.value.load(ordering: .relaxed) == 0, "records whose name or thread entry the image lacks")
    }

    /// The runtime's write methods are what trace points call: past their category gate they publish into
    /// the attached ring, stamped by the runtime's clock, and the first attached ring stays.
    @Test("A runtime publishes catalog and interned writes into its attached ring")
    func runtimeWritesIntoItsRing() throws {
        let runtime = TraceRuntime(role: .app, clock: TraceClock(reader: TraceClock.Reader(
            uptimeNanos: { 5_000 }, continuousNow: { ContinuousClock.now })))
        let ring = Self.ring()
        #expect(runtime.attach(ring))
        #expect(!runtime.attach(Self.ring()), "the first ring stays")
        let name = TraceRuntime.InternedName("cmux.io.read", categoryBit: 6)
        runtime.write(name: 2, categoryBit: 1, phase: .begin, arg0: 1)
        runtime.write(name, phase: .instant, arg0: 2)
        #expect(try #require(ring.decodedImage()).records.isEmpty, "both categories are off")
        runtime.setCategoryMask(1 << 1 | 1 << 6)
        runtime.write(name: 2, categoryBit: 1, phase: .begin, arg0: 3)
        runtime.write(name, phase: .instant, flags: .asyncID, arg0: 4, arg1: 9)
        let image = try #require(ring.decodedImage())
        #expect(image.records.map(\.arg0) == [3, 4])
        #expect(image.records.map { image.name(of: $0) } == ["key.frame", "cmux.io.read"])
        #expect(image.records.map(\.phase) == [.begin, .instant])
        #expect(image.records.map(\.flags) == [0, 1])
        #expect(image.records.allSatisfy { $0.timestamp == 5_000 })
        #expect(runtime.stubRecordCount.load(ordering: .relaxed) == 0, "a runtime with a ring counts nothing on the side")
    }

    @Test("Every runtime phase is the record phase with the same byte")
    func phasesMatch() {
        for phase in TraceRuntime.Phase.allCases {
            #expect(phase.recordPhase.rawValue == phase.rawValue, "\(phase)")
        }
        #expect(TraceRuntime.Phase.allCases.count == TraceRecord.Phase.allCases.count)
    }

    /// Interned writes after the first cost what catalog-id writes cost (the tagged id is one relaxed load):
    /// the median 31-record batch of each, in one thread. Optimized builds only, as the ring's contention
    /// check (TraceRingTests); elsewhere the test shows as skipped. The `trace-ring-write-interned` bench.
    @Test("Interned writes after first use keep the catalog-id write's cost",
          .enabled(if: !_isDebugAssertConfiguration(), "needs an optimized build (-c release)"))
    func internedWriteCost() {
        let catalog = (0 ..< 3).map { _ in Self.batchMedian(interned: false) }.min() ?? 0
        let interned = (0 ..< 3).map { _ in Self.batchMedian(interned: true) }.min() ?? 0
        print("trace ring batch p50: catalog id \(catalog) ns, interned \(interned) ns")
        #expect(Double(interned) <= Double(catalog) * 1.2 + 31, "interned \(interned) ns, catalog id \(catalog) ns")
    }

    /// The median nanoseconds of a 31-record batch (one chunk claim and 31 writes) on a new thread.
    private static func batchMedian(interned: Bool) -> UInt64 {
        let batches = 4000
        let ring = TraceRing(records: (batches + 2) * TraceRing.recordsPerChunk, role: .app)
        let name = TraceRuntime.InternedName("bench.interned", categoryBit: 0)
        let median = SharedCount()
        runOnThreads(1) { _ in
            ring.write(name, phase: .instant, timestamp: 0)
            var local = [UInt64](repeating: 0, count: batches)
            for batch in 0 ..< batches {
                let start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
                for index in 0 ..< TraceRing.recordsPerChunk {
                    if interned {
                        ring.write(name, phase: .instant, timestamp: start, arg0: UInt64(index))
                    } else {
                        ring.write(name: 1, phase: .instant, timestamp: start, arg0: UInt64(index))
                    }
                }
                local[batch] = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - start
            }
            local.sort()
            median.value.store(Int(local[batches / 2]), ordering: .relaxed)
        }
        return UInt64(median.value.load(ordering: .relaxed))
    }

    /// The heap's entries are copied into the file, and a name used after the swap is interned in the file
    /// under its own slot: records on both sides of the adoption read the same text.
    @Test("An interned name reads the same in the heap's and the file's records")
    func internedAcrossAdoption() throws {
        let directory = try TraceRingCheck.temporaryDirectory()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let ring = Self.ring(identity: TraceRing.Identity(pid: 4040, role: .app))
        let name = TraceRuntime.InternedName("cmux.io.read", categoryBit: 6)
        ring.write(name, phase: .begin, timestamp: 1, arg0: 1)
        let file = try #require(TraceRingFile.adopt(ring, directory: directory))
        ring.write(name, phase: .end, timestamp: 2, arg0: 2)
        #expect(name.cachedID(inSlot: 0) != 0 && name.cachedID(inSlot: 1) != 0, "one id in the heap's slot and one in the file's")
        let bytes = try [UInt8](#require(FileManager.default.contents(atPath: file.path)))
        let image = try #require(TraceRing.Image(bytes: bytes))
        #expect(image.records.map(\.arg0) == [1, 2])
        #expect(image.records.map { image.name(of: $0) } == ["cmux.io.read", "cmux.io.read"])
    }

    @Test("The header carries the writer's build id and version")
    func buildIdentity() throws {
        let uuid = TraceRing.Identity.mainImageBuildUUID()
        #expect(uuid.count == 16)
        #expect(uuid.contains { $0 != 0 }, "the linker gives every executable an LC_UUID")
        #expect(TraceRing.Identity.mainImageBuildUUID() == uuid)
        let ring = Self.ring(identity: TraceRing.Identity(pid: 99, role: .daemon, buildUUID: uuid, buildVersion: "1.2.3 (45) abcdef0"))
        let header = try #require(TraceRing.Image(bytes: ring.image())).header
        #expect(header.buildUUID == uuid)
        #expect(header.buildVersion == "1.2.3 (45) abcdef0")
        #expect(header.pid == 99)
        #expect(header.role == .daemon)
    }

    /// The fixture the Rust writer made (`cmux-trace` tests/ring.rs, `golden_bytes`): its names and threads
    /// decode from the file alone.
    @Test("The shared golden ring decodes its names and threads")
    func goldenTables() throws {
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/ring-v1-golden.cmxtrace").path
        let bytes = try #require(FileManager.default.contents(atPath: path))
        let image = try #require(TraceRing.Image(bytes: [UInt8](bytes)))
        #expect(image.names.map(\.text) == ["key.frame", "daemon.request", "key", "cmux.io.read"])
        #expect(image.names.map(\.kindCode) == [1, 1, 3, 2])
        #expect(image.threads.map(\.name) == ["main", "cmux-io"])
        #expect(image.threads.map(\.tid) == [101, 202])
        #expect(image.threads.map(\.qos) == [0x21, 0x19])
        #expect(image.threads.allSatisfy { $0.state == .exited && $0.generation == 0 })
        let interned = try #require(image.records.first { $0.timestamp == 1375 })
        #expect(image.name(of: interned) == "cmux.io.read")
        #expect(image.threadLabel(of: interned) == "cmux-io")
        #expect(image.header.buildVersion == "1.2.3 (45) abcdef0")
        #expect(image.header.buildUUID == (0 ..< 16).map { 0x20 + UInt8($0) })
        #expect(image.header.role == .daemon)
    }
}
