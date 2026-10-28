#if DEBUG || CMUX_BENCH_HOOKS
import CmuxNextCompat
import CmuxNextOracle
import Foundation
import Testing

/// The ax facet: per window, the kept AX elements in preorder with role, the localization key of
/// their name (never the text), enabled, focused and depth; the tree is read in the main-actor turn and the keys off
/// it. Run: `swift test --filter OracleAccessibilityFacetTests`.
@MainActor
struct OracleAccessibilityFacetTests {
    typealias Facet = OracleAccessibilityFacet

    private static func table(_ name: String, _ strings: [String: String]) throws -> Facet.StringTable {
        Facet.StringTable(name: name, data: try PropertyListSerialization.data(fromPropertyList: strings, format: .binary, options: 0))
    }

    private static func index(_ strings: [String: String]) throws -> Facet.StringIndex {
        try Facet.StringIndex([try table("Localizable.strings", strings)])
    }

    private let tree = [Facet.Window(id: "win_a", nodes: [
        Facet.Node(role: "AXButton", names: ["New Tab"], enabled: true, focused: false, depth: 0),
        Facet.Node(role: "AXTextField", names: ["~/secret-project", "Search"], enabled: true, focused: true, depth: 1),
        Facet.Node(role: "AXRow", names: ["my private tab title"], enabled: false, focused: false, depth: 1),
        Facet.Node(role: "AXCheckBox", names: [], enabled: true, focused: false, depth: 0),
    ])]

    /// Each node's labelKey is the key of its first name that has one; a name that is no app string is null.
    @Test func nodesCarryTheirLabelKeyInPreorder() throws {
        let value = Facet.value(tree, index: try Self.index(["action.newTab": "New Tab", "find.placeholder": "Search"]))
        let expected: OracleValue = ["windows": [[
            "window": "win_a",
            "nodes": [
                ["role": "AXButton", "labelKey": "action.newTab", "enabled": true, "focused": false, "depth": 0],
                ["role": "AXTextField", "labelKey": "find.placeholder", "enabled": true, "focused": true, "depth": 1],
                ["role": "AXRow", "labelKey": nil, "enabled": false, "focused": false, "depth": 1],
                ["role": "AXCheckBox", "labelKey": nil, "enabled": true, "focused": false, "depth": 0],
            ],
        ]]]
        #expect(value == expected)
    }

    /// The facet never holds a shown text: only keys, roles and flags.
    @Test func noNameReachesTheFacet() throws {
        func strings(_ value: OracleValue) -> [String] {
            switch value {
            case .string(let text): [text]
            case .array(let items): items.flatMap(strings)
            case .object(let members): members.keys.map { $0 } + members.values.flatMap(strings)
            default: []
            }
        }
        let recorded = Set(strings(Facet.value(tree, index: try Self.index(["action.newTab": "New Tab"]))))
        for name in tree.flatMap({ $0.nodes.flatMap(\.names) }) {
            #expect(!recorded.contains(name), "\(name) reached the facet")
        }
    }

    /// A text that several keys show (in one table or two) is ambiguous: no key is guessed for it, whatever the order
    /// of the tables. An element that names its key (its AX identifier) gets that key, whatever its text.
    @Test func aSharedTextIsAmbiguousUnlessTheElementNamesItsKey() throws {
        let tables = [try Self.table("ActionCatalog.strings", ["action.browserBack": "Back", "action.newTab": "New Tab"]),
                      try Self.table("Markdown.strings", ["action.markdownBack": "Back"])]
        let back = Facet.Node(role: "AXButton", names: ["Back"], enabled: true, focused: false, depth: 0)
        let markdownBack = Facet.Node(role: "AXButton", identifier: "action.markdownBack", names: ["Back"], enabled: true,
                                      focused: false, depth: 0)
        let newTab = Facet.Node(role: "AXButton", names: ["New Tab"], enabled: true, focused: false, depth: 0)
        for order in [tables, tables.reversed()] {
            let index = try Facet.StringIndex(order)
            #expect(index.labelKey(of: back) == Facet.ambiguousKey)
            #expect(index.labelKey(of: markdownBack) == "action.markdownBack")
            #expect(index.labelKey(of: newTab) == "action.newTab")
        }
    }

    /// An identifier that is no key of the tables (an automation id) is not a key: the shown text decides.
    @Test func anIdentifierThatIsNoKeyIsIgnored() throws {
        let index = try Self.index(["settings.title": "Settings"])
        let node = Facet.Node(role: "AXButton", identifier: "SettingsButton", names: ["Settings"], enabled: true, focused: false, depth: 0)
        #expect(index.labelKey(of: node) == "settings.title")
    }

    /// The text form of a `.strings` table parses too (a table copied without compiling).
    @Test func aTextStringsTableParses() throws {
        let table = Facet.StringTable(name: "Localizable.strings", data: Data("\"settings.title\" = \"Settings\";\n".utf8))
        let node = Facet.Node(role: "AXButton", names: ["Settings"], enabled: true, focused: false, depth: 0)
        #expect(try Facet.StringIndex([table]).labelKey(of: node) == "settings.title")
    }

    /// The tables come from each resource bundle in the localization it shows. Off the main actor, as the facet
    /// reads them.
    @Test nonisolated func theTablesComeFromTheResourceBundles() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "oracle-ax-\(UUID().uuidString)")
        defer { try? FileManager.checked.removeItem(at: root) }
        let lproj = root.appending(path: "Fixture_Strings.bundle/en.lproj")
        try FileManager.checked.createDirectory(at: lproj, withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["oracle.fixture.title": "Oracle Fixture Title"], format: .binary, options: 0)
            .blockingWrite(to: lproj.appending(path: "Fixture.strings"))
        let tables = try Facet.StringTable.bundleTables(resources: root)
        #expect(tables.contains { $0.name == "Fixture.strings" })
        let node = Facet.Node(role: "AXButton", names: ["Oracle Fixture Title"], enabled: true, focused: false, depth: 0)
        #expect(try Facet.StringIndex(tables).labelKey(of: node) == "oracle.fixture.title")
    }

    /// A table that does not parse fails the read, naming it: its names would otherwise turn null unseen.
    @Test func aTableThatDoesNotParseFailsNamingIt() {
        let broken = Facet.StringTable(name: "Broken.strings", data: Data([0xff, 0x00, 0x13]))
        #expect(throws: OracleFacetError("string table Broken.strings is not a property list of strings")) {
            try Facet.StringIndex([broken])
        }
    }

    /// The tree is read in the main-actor turn (beginCapture), the tables after it (finish), once for the facet list;
    /// a wait cannot observe the facet, so it is not waitable.
    @Test func theTreeIsReadInTheTurnAndTheTablesOnceAfterIt() async throws {
        let reads = Counter(), loads = Loads()
        let tree = tree, index = try Self.index(["action.newTab": "New Tab"])
        let facet = Facet(read: { reads.count += 1; return tree }, index: {
            await loads.record()
            return index
        })
        let facets = OracleFacets([facet])
        #expect(facets.provided == [.ax])
        #expect(!facets.signalsChanges(.ax))
        let capture = try facets.beginCapture([.ax])
        #expect(reads.count == 1, "the tree is read in beginCapture's turn")
        #expect(capture.completed == nil, "the tables are read off the main actor")
        #expect(try await capture.finish()["ax"] == Facet.value(tree, index: index))
        #expect(try await facets.beginCapture([.ax]).finish()["ax"] == Facet.value(tree, index: index))
        #expect(reads.count == 2)
        #expect(await loads.count == 1, "the tables do not change while the app runs: read once")
    }

    /// No names, no table read: a tree with no named node never touches the tables.
    @Test func aTreeWithNoNamesReadsNoTables() async throws {
        let loads = Loads(), empty = try Self.index([:])
        let facet = Facet(read: { [Facet.Window(id: "win_a", nodes: [])] }, index: {
            await loads.record()
            return empty
        })
        let value = try await OracleFacets([facet]).beginCapture([.ax]).finish()
        #expect(value["ax"] == ["windows": [["window": "win_a", "nodes": []]]])
        #expect(await loads.count == 0)
    }

    /// A failed walk or table read fails the snapshot, naming the facet; a failed table read is tried again next time.
    @Test func aFailedReadFailsTheSnapshot() async throws {
        let empty = try Self.index([:])
        let walk = Facet(read: { () throws(OracleFacetError) -> [Facet.Window] in throw OracleFacetError("walk") }, index: { empty })
        #expect(throws: OracleSnapshotError(facet: .ax, error: OracleFacetError("walk"))) {
            try OracleFacets([walk]).beginCapture([.ax])
        }
        let tree = tree, loads = Loads()
        let tables = Facet(read: { tree }, index: { () async throws(OracleFacetError) -> Facet.StringIndex in
            await loads.record()
            throw OracleFacetError("tables")
        })
        let facets = OracleFacets([tables])
        for _ in 0..<2 {
            let capture = try facets.beginCapture([.ax])
            await #expect(throws: OracleSnapshotError(facet: .ax, error: OracleFacetError("tables"))) {
                try await capture.finish()
            }
        }
        #expect(await loads.count == 2)
    }
}

@MainActor private final class Counter {
    var count = 0
}

private actor Loads {
    private(set) var count = 0

    func record() { count += 1 }
}
#endif
