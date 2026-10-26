import CmuxNextCompat
@testable import CmuxNextTrace
import Foundation
import Testing

/// The ring's name table (p09-observability-004): fixed catalog ids, category entries, names interned once
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
        #expect(name.ringIDs.load(ordering: .relaxed) == UInt64(entry.id), "slot 0 (the heap) keeps the id")
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
        #expect(ids.first.map(UInt64.init) == name.ringIDs.load(ordering: .relaxed))
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
        #expect(overflows.ringIDs.load(ordering: .relaxed) == 0)
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
        let ids = name.ringIDs.load(ordering: .relaxed)
        #expect(ids & 0xFFFF != 0 && ids >> 16 & 0xFFFF != 0, "one id in the heap's slot and one in the file's")
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
        let image = try #require(TraceRing.Image(bytes: [UInt8](#require(FileManager.default.contents(atPath: path)))))
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
