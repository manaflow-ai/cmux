#if DEBUG || CMUX_BENCH_HOOKS
import CmuxNextOracle
import Testing

/// The overlays facet (p15-oracle-038): the schema's object from the host's reading, typed text only through the
/// injected hash, at most ten palette rows, hover targets as item ids, and not-comparable with its task when the
/// host has no owners to read. Run: `swift test --filter OracleOverlaysFacetTests`.
@MainActor
struct OracleOverlaysFacetTests {
    /// Marks hashed text, so a test sees the text went through the hash and never in raw.
    nonisolated static func hash(_ text: String) -> String { "hashed(\(text.count))" }

    @Test func nothingOpenIsTheClosedForm() throws {
        let facet = OracleOverlaysFacet(hash: Self.hash) { OracleOverlaysFacet.Reading() }
        #expect(facet.facet == .overlays)
        let snapshot = try #require(try OracleFacets([facet]).beginCapture([.overlays]).completed)
        #expect(snapshot["overlays"] == [
            "stack": [],
            "palette": ["open": false, "mode": nil, "querySha256": nil, "topIds": [], "selectedIndex": nil],
            "dialog": ["specId": nil],
            "hoverCard": ["target": nil],
            "findBar": ["open": false, "pane": nil, "querySha256": nil, "matches": 0, "selected": nil],
        ])
    }

    @Test func anOpenPaletteAndFindBarAreTheirIDsAndHashes() throws {
        let reading = OracleOverlaysFacet.Reading(
            stack: [.init(.findBar, window: "win_1"), .init(.palette, window: "win_1"), .init(.dialog, window: nil)],
            palette: .init(open: true, mode: "commands", query: "split", rowIDs: (0..<14).map { "action:a\($0)" }, selectedIndex: 2),
            dialogSpecID: "cmux.dialog.close", hoverCardTarget: "tab_9",
            findBar: .init(open: true, pane: "pane_1", query: "error!", matches: 7, selected: 0)
        )
        let facet = OracleOverlaysFacet(hash: Self.hash) { reading }
        let value = try #require(try OracleFacets([facet]).beginCapture([.overlays]).completed?["overlays"])
        #expect(value == [
            "stack": [["kind": "findBar", "window": "win_1"], ["kind": "palette", "window": "win_1"], ["kind": "dialog", "window": nil]],
            "palette": ["open": true, "mode": "commands", "querySha256": "hashed(5)",
                        "topIds": .array((0..<10).map { .string("action:a\($0)") }), "selectedIndex": 2],
            "dialog": ["specId": "cmux.dialog.close"],
            "hoverCard": ["target": "tab_9"],
            "findBar": ["open": true, "pane": "pane_1", "querySha256": "hashed(6)", "matches": 7, "selected": 0],
        ])
    }

    @Test func noOwnersIsNotComparable() throws {
        let facet = OracleOverlaysFacet(hash: Self.hash) { nil }
        let snapshot = try #require(try OracleFacets([facet]).beginCapture([.overlays]).completed)
        #expect(snapshot["overlays"]?["status"] == "not-comparable")
        #expect(snapshot["overlays"]?["task"] == "p15-oracle-038")
    }

    @Test func aHoverTargetIsItsItemsID() {
        let publicID = { (id: String) in "ws_public_\(id)" }
        #expect(OracleOverlaysFacet.itemID(ofHoverTarget: "ws:W1", workspaceID: publicID) == "ws_public_W1")
        #expect(OracleOverlaysFacet.itemID(ofHoverTarget: "rail:W2", workspaceID: publicID) == "ws_public_W2")
        #expect(OracleOverlaysFacet.itemID(ofHoverTarget: "tab:tab_9", workspaceID: publicID) == "tab_9")
        #expect(OracleOverlaysFacet.itemID(ofHoverTarget: "grp:grp_3", workspaceID: publicID) == "grp_3")
        // A link chip's target holds its URL: private text never goes in.
        #expect(OracleOverlaysFacet.itemID(ofHoverTarget: "homeChip:https://example.com/a", workspaceID: publicID) == nil)
        #expect(OracleOverlaysFacet.itemID(ofHoverTarget: "sidebar:pull-requests", workspaceID: publicID) == nil)
        #expect(OracleOverlaysFacet.itemID(ofHoverTarget: "tab:", workspaceID: publicID) == nil)
        #expect(OracleOverlaysFacet.itemID(ofHoverTarget: "nocolon", workspaceID: publicID) == nil)
    }

    /// Every kind the facet can name is one the schema's `stack[*].kind` enum lists.
    @Test func theKindsAreTheSchemas() {
        #expect(OracleOverlaysFacet.Kind.allCases.map(\.rawValue)
            == ["palette", "dialog", "hoverCard", "findBar", "popover", "menu", "sheet", "toast", "refusalHud"])
    }
}
#endif
