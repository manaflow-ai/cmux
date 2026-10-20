import CmuxNextFileGrid
import Foundation
import Testing

/// The grid's newest-first listing: order, live updates and filters.
@Suite struct FileGridListingTests {
    static func item(_ name: String, at seconds: TimeInterval, source: String = "a", size: Int64 = 1) -> FileGridItem {
        FileGridItem(url: URL(fileURLWithPath: "/shots/\(source)/\(name)"), size: size,
                     modified: Date(timeIntervalSinceReferenceDate: seconds), sourceID: source)
    }

    @Test func listsNewestFirstThenByNumericName() {
        let listing = FileGridListing([
            Self.item("Shot 10.png", at: 5), Self.item("Shot 2.png", at: 5), Self.item("old.png", at: 1), Self.item("new.mov", at: 9),
        ])
        #expect(listing.items.map(\.name) == ["new.mov", "Shot 2.png", "Shot 10.png", "old.png"])
    }

    @Test func upsertPlacesANewScreenshotFirstAndMovesARewrittenFile() {
        var listing = FileGridListing([Self.item("a.png", at: 1), Self.item("b.png", at: 2)])
        listing.upsert(Self.item("c.png", at: 3))
        #expect(listing.items.map(\.name) == ["c.png", "b.png", "a.png"])
        listing.upsert(Self.item("a.png", at: 4, size: 9))
        #expect(listing.items.map(\.name) == ["a.png", "c.png", "b.png"])
        #expect(listing.count == 3)
        #expect(listing.item(at: "/shots/a/a.png")?.size == 9)
    }

    @Test func removeDropsOnlyThatPath() {
        var listing = FileGridListing([Self.item("a.png", at: 1), Self.item("b.png", at: 2)])
        listing.remove(path: "/shots/a/a.png")
        listing.remove(path: "/shots/a/missing.png")
        #expect(listing.items.map(\.name) == ["b.png"])
    }

    @Test func replaceSwapsOneSourceAndKeepsTheOthers() {
        var listing = FileGridListing([Self.item("a.png", at: 1, source: "a"), Self.item("b.png", at: 2, source: "b")])
        listing.replace(source: "a", with: [Self.item("c.png", at: 3, source: "a")])
        #expect(listing.items.map(\.name) == ["c.png", "b.png"])
        listing.removeSource("b")
        #expect(listing.items.map(\.name) == ["c.png"])
        #expect(listing.countsBySource == ["a": 1])
    }

    @Test func filtersByNameAndSource() {
        let listing = FileGridListing([
            Self.item("Screenshot one.png", at: 3, source: "a"), Self.item("Recording.mov", at: 2, source: "b"),
            Self.item("screenshot two.png", at: 1, source: "b"),
        ])
        #expect(listing.filtered(query: "SCREENSHOT", sources: nil).map(\.name) == ["Screenshot one.png", "screenshot two.png"])
        #expect(listing.filtered(query: "", sources: ["b"]).map(\.name) == ["Recording.mov", "screenshot two.png"])
        #expect(listing.filtered(query: "two", sources: ["a"]).isEmpty)
    }

    /// Any sequence of upserts and removes leaves the same list a full sort of the survivors gives.
    @Test(arguments: [1, 7, 42, 1999])
    func incrementalUpdatesMatchAFullSort(seed: UInt64) {
        var generator = SeededGenerator(seed: seed)
        var listing = FileGridListing()
        var truth: [String: FileGridItem] = [:]
        for _ in 0..<600 {
            let name = "f\(Int.random(in: 0..<80, using: &generator)).png"
            if Int.random(in: 0..<4, using: &generator) == 0 {
                listing.remove(path: "/shots/a/\(name)")
                truth["/shots/a/\(name)"] = nil
            } else {
                let item = Self.item(name, at: TimeInterval(Int.random(in: 0..<20, using: &generator)))
                listing.upsert(item)
                truth[item.id] = item
            }
        }
        #expect(listing.items == truth.values.sorted(by: FileGridListing.precedes))
    }

    /// A screenshot landing in a folder of 20 000 files is placed without a re-sort.
    @Test func upsertIntoALargeListingStaysFast() {
        var listing = FileGridListing((0..<20_000).map { Self.item("f\($0).png", at: TimeInterval($0)) })
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            for index in 0..<500 { listing.upsert(Self.item("new\(index).png", at: 30_000 + TimeInterval(index))) }
        }
        #expect(listing.items.first?.name == "new499.png")
        #expect(elapsed < .seconds(1), "500 upserts into 20 000 items took \(elapsed)")
    }
}

/// A deterministic random source for property tests (SplitMix64).
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}
