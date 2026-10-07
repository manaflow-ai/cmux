@testable import CmuxNextApp
import CmuxNextSettings
import Foundation
import Testing

/// The icon picker's SF Symbol catalog (ICON-PICKER-ALL-EMOJI-AND-SF-SYMBOLS, S3 a): the
/// system's names, order, keywords and categories from CoreGlyphs.bundle, read from small
/// fixture plists in the real formats (plutil -p of the macOS 27 files), and what the page
/// receives with the first session.
@MainActor
struct IconPickerCatalogTests {
    /// A CoreGlyphs-like Resources directory with the five plists, plus a snapshot file.
    static func fixture() throws -> (resources: URL, snapshot: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("icon-catalog-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        func write(_ name: String, _ value: Any) throws {
            let data = try PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0)
            try data.write(to: root.appendingPathComponent("\(name).plist"))
        }
        try write("name_availability", ["symbols": ["car": "2019", "star": "2019", "star.fill": "2019", "zz.newer": "2099", "Bad Name": "2019"]])
        try write("symbol_order", ["car", "star", "not.on.this.mac", "star.fill"])
        // Base names only, as in the system files: star.fill takes star's entries.
        try write("symbol_categories", ["star": ["multicolor", "objectsandtools"], "car": ["transportation"]])
        try write("symbol_search", ["star": ["favorite", "vip"], "car": ["automobile"]])
        try write("categories", [
            ["key": "all", "icon": "square.grid.2x2"],
            ["key": "multicolor", "icon": "paintpalette"],
            ["key": "objectsandtools", "icon": "folder"],
            ["key": "transportation", "icon": "car.fill"],
            ["key": "broken", "icon": "Not A Symbol"],
        ])
        let snapshot = root.appendingPathComponent("snapshot.txt")
        try "aa.snapshot.only\nstar\n".write(to: snapshot, atomically: true, encoding: .utf8)
        return (root, snapshot)
    }

    @Test func theSystemCatalogOrdersKeywordsAndCategorizesTheNames() throws {
        let (resources, snapshot) = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: resources) }
        let catalog = IconPickerSymbolCatalog.read(resources: resources, snapshot: snapshot)
        // The system order first (only names this Mac has), then the rest sorted; invalid names dropped.
        #expect(catalog.names == ["car", "star", "star.fill", "aa.snapshot.only", "zz.newer"])
        #expect(catalog.keywords == ["automobile", "favorite vip", "favorite vip", "", ""])
        #expect(catalog.categories == [
            .init(key: "all", icon: "square.grid.2x2", members: []),
            .init(key: "multicolor", icon: "paintpalette", members: [1, 2]),
            .init(key: "objectsandtools", icon: "folder", members: [1, 2]),
            .init(key: "transportation", icon: "car.fill", members: [0]),
        ])
    }

    /// The Symbols tab is never empty: the bundled snapshot when the system catalog is missing.
    @Test func aMissingSystemCatalogLeavesTheBundledSnapshot() async {
        let catalog = await IconPickerSymbolCatalog.load(resources: URL(fileURLWithPath: "/nonexistent", isDirectory: true))
        #expect(catalog.names.count > 5_000)
        #expect(catalog.names.contains("star.fill") && catalog.names == catalog.names.sorted())
        #expect(catalog.keywords.count == catalog.names.count && catalog.keywords.allSatisfy(\.isEmpty))
        #expect(catalog.categories.isEmpty)
    }

    /// The running system's files (macOS 13 and later ship all five).
    @Test func theRunningSystemHasCategoriesAndKeywords() async {
        let catalog = await IconPickerSymbolCatalog.load()
        let star = catalog.names.firstIndex(of: "star")
        #expect(star != nil)
        #expect(catalog.categories.contains { $0.key == "multicolor" && !$0.members.isEmpty })
        #expect(catalog.keywords.contains { !$0.isEmpty })
    }

    @Test func theFirstSessionCarriesTheCatalog() {
        let catalog = IconPickerSymbolCatalog(names: ["star", "car"], keywords: ["favorite vip", ""],
                                              categories: [.init(key: "transportation", icon: "car.fill", members: [1])])
        let event = IconPickerSession(id: "s", current: "star.fill", catalog: catalog, maxEmojiVersion: 160).event
        #expect(event["symbols"] == .array([.string("star"), .string("car")]))
        #expect(event["symbolKeywords"] == .array([.string("favorite vip"), .string("")]))
        #expect(event["symbolCategories"] == .array([
            .object(["key": .string("transportation"), "icon": .string("car.fill"), "members": .array([JSONValue(1)])]),
        ]))
        #expect(event["maxEmojiVersion"] == JSONValue(160))
        // A later session of the same page sends none of it.
        #expect(IconPickerSession(id: "s2", current: nil).event["symbols"] == nil)
    }
}
