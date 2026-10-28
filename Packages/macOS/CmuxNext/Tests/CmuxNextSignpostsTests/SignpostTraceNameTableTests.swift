import CmuxNextSignposts
import CmuxNextTrace
import Testing

/// The catalog a ring's creator writes into the header name table: every
/// ``SignpostName`` at its pinned id and every category after them, decoded back from the ring alone.
@Suite("Signpost trace name table")
struct SignpostTraceNameTableTests {
    @Test("Every catalog name sits at its id, and each category follows the last name")
    func catalogEntries() {
        let catalog = SignpostName.traceCatalog
        let names = catalog.filter { $0.kind == TraceRing.NameEntry.Kind.catalog.rawValue }
        #expect(names.map(\.id) == SignpostName.allCases.map(\.rawValue))
        for (entry, name) in zip(names, SignpostName.allCases) {
            #expect(String(describing: entry.text) == name.description)
            #expect(entry.category == name.traceCategory.traceBit)
        }
        let categories = catalog.filter { $0.kind == TraceRing.NameEntry.Kind.category.rawValue }
        let lastName = SignpostName.allCases.map(\.rawValue).max() ?? 0
        #expect(categories.count == SignpostCategory.allCases.count)
        for (entry, category) in zip(categories, SignpostCategory.allCases) {
            #expect(String(describing: entry.text) == category.rawValue)
            #expect(entry.category == category.traceBit)
            #expect(entry.id == lastName + 1 + UInt16(category.traceBit))
        }
        #expect(Set(catalog.map(\.id)).count == catalog.count)
    }

    /// The smallest role's ring (the terminal host: 1024 names, trace.md "Sizes by role") holds the whole
    /// catalog, and a decoder names every catalog id from the ring's own table.
    @Test("A ring made with the catalog names every id from its own table")
    func ringHoldsTheCatalog() throws {
        let ring = TraceRing(sizes: TraceRing.Sizes(nameCapacity: 1024, threadCapacity: 256, chunkCount: 8),
                             identity: TraceRing.Identity(pid: 1, role: .terminalHost), catalog: SignpostName.traceCatalog)
        ring.write(name: SignpostName.keyToFrame.rawValue, phase: .instant, timestamp: 1)
        let image = try #require(TraceRing.Image(bytes: ring.image()))
        #expect(image.header.nameOverflow == 0)
        for name in SignpostName.allCases {
            #expect(image.name(name.rawValue) == name.description)
        }
        let record = try #require(image.records.first)
        #expect(image.name(of: record) == "key.frame")
    }
}
