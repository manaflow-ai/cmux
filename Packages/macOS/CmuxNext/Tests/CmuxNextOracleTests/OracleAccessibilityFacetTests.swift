#if DEBUG || CMUX_BENCH_HOOKS
import CmuxNextOracle
import Foundation
import Testing

/// The ax facet (p15-oracle-216): per window, the kept AX elements in preorder with role, the localization key of
/// their name (never the text), enabled, focused and depth; the tree is read in the main-actor turn and the keys off
/// it. Run: `swift test --filter OracleAccessibilityFacetTests`.
@MainActor
struct OracleAccessibilityFacetTests {
    typealias Facet = OracleAccessibilityFacet

    private static func table(_ name: String, _ strings: [String: String]) throws -> Facet.StringTable {
        Facet.StringTable(name: name, data: try PropertyListSerialization.data(fromPropertyList: strings, format: .binary, options: 0))
    }

    private let tree = [Facet.Window(id: "win_a", nodes: [
        Facet.Node(role: "AXButton", names: ["New Tab"], enabled: true, focused: false, depth: 0),
        Facet.Node(role: "AXTextField", names: ["~/secret-project", "Search"], enabled: true, focused: true, depth: 1),
        Facet.Node(role: "AXRow", names: ["my private tab title"], enabled: false, focused: false, depth: 1),
        Facet.Node(role: "AXCheckBox", names: [], enabled: true, focused: false, depth: 0),
    ])]

    /// Each node's labelKey is the key of its first name that has one; a name that is no app string is null.
    @Test func nodesCarryTheirLabelKeyInPreorder() {
        let value = Facet.value(tree, keys: ["New Tab": "action.newTab", "Search": "find.placeholder"])
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
    @Test func noNameReachesTheFacet() {
        func strings(_ value: OracleValue) -> [String] {
            switch value {
            case .string(let text): [text]
            case .array(let items): items.flatMap(strings)
            case .object(let members): members.keys.map { $0 } + members.values.flatMap(strings)
            default: []
            }
        }
        let recorded = Set(strings(Facet.value(tree, keys: ["New Tab": "action.newTab"])))
        for name in tree.flatMap({ $0.nodes.flatMap(\.names) }) {
            #expect(!recorded.contains(name), "\(name) reached the facet")
        }
    }

    /// A text that several keys show takes the smallest key whatever the order of the tables; texts not asked for
    /// are not returned.
    @Test func aSharedTextTakesTheSmallestKeyInAnyTableOrder() throws {
        let tables = [try Self.table("ActionCatalog.strings", ["action.closeTab": "Close", "action.newTab": "New Tab"]),
                      try Self.table("Localizable.strings", ["close": "Close", "zoom": "Zoom"])]
        let names: Set = ["Close", "New Tab"]
        let expected = ["Close": "action.closeTab", "New Tab": "action.newTab"]
        #expect(try Facet.keys(for: names, in: tables) == expected)
        #expect(try Facet.keys(for: names, in: tables.reversed()) == expected)
    }

    /// The text form of a `.strings` table parses too (a table copied without compiling).
    @Test func aTextStringsTableParses() throws {
        let table = Facet.StringTable(name: "Localizable.strings", data: Data("\"settings.title\" = \"Settings\";\n".utf8))
        #expect(try Facet.keys(for: ["Settings"], in: [table]) == ["Settings": "settings.title"])
    }

    /// A table that does not parse fails the read, naming it: its names would otherwise turn null unseen.
    @Test func aTableThatDoesNotParseFailsNamingIt() {
        let broken = Facet.StringTable(name: "Broken.strings", data: Data([0xff, 0x00, 0x13]))
        #expect(throws: OracleFacetError("string table Broken.strings is not a property list of strings")) {
            try Facet.keys(for: ["Settings"], in: [broken])
        }
    }

    /// The tree is read in the main-actor turn (beginCapture), the keys after it (finish), only for the names found;
    /// a wait cannot observe the facet, so it is not waitable.
    @Test func theTreeIsReadInTheTurnAndTheKeysAfterIt() async throws {
        let reads = Counter(), asked = Asked()
        let tree = tree
        let facet = Facet(read: { reads.count += 1; return tree }, keys: { names in
            await asked.record(names)
            return ["New Tab": "action.newTab"]
        })
        let facets = OracleFacets([facet])
        #expect(facets.provided == [.ax])
        #expect(!facets.signalsChanges(.ax))
        let capture = try facets.beginCapture([.ax])
        #expect(reads.count == 1, "the tree is read in beginCapture's turn")
        #expect(capture.completed == nil, "the keys are read off the main actor")
        let value = try await capture.finish()
        #expect(value["ax"] == Facet.value(tree, keys: ["New Tab": "action.newTab"]))
        #expect(await asked.names == [Set(tree.flatMap { $0.nodes.flatMap(\.names) })])
    }

    /// No names, no key read: a tree with no named node never touches the tables.
    @Test func aTreeWithNoNamesReadsNoKeys() async throws {
        let asked = Asked()
        let facet = Facet(read: { [Facet.Window(id: "win_a", nodes: [])] }, keys: { names in
            await asked.record(names)
            return [:]
        })
        let value = try await OracleFacets([facet]).beginCapture([.ax]).finish()
        #expect(value["ax"] == ["windows": [["window": "win_a", "nodes": []]]])
        #expect(await asked.names.isEmpty)
    }

    /// A failed walk or key read fails the snapshot, naming the facet.
    @Test func aFailedReadFailsTheSnapshot() async throws {
        let walk = Facet(read: { () throws(OracleFacetError) -> [Facet.Window] in throw OracleFacetError("walk") }, keys: { _ in [:] })
        #expect(throws: OracleSnapshotError(facet: .ax, error: OracleFacetError("walk"))) {
            try OracleFacets([walk]).beginCapture([.ax])
        }
        let tree = tree
        let keys = Facet(read: { tree }, keys: { (_: Set<String>) async throws(OracleFacetError) -> [String: String] in
            throw OracleFacetError("tables")
        })
        let capture = try OracleFacets([keys]).beginCapture([.ax])
        await #expect(throws: OracleSnapshotError(facet: .ax, error: OracleFacetError("tables"))) {
            try await capture.finish()
        }
    }
}

@MainActor private final class Counter {
    var count = 0
}

private actor Asked {
    private(set) var names: [Set<String>] = []

    func record(_ names: Set<String>) { self.names.append(names) }
}
#endif
