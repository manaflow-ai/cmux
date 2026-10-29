#if DEBUG || CMUX_BENCH_HOOKS
import CmuxNextOracle
import Testing

/// The overlays facet: the schema's object from the host's reading, each window's layers in their
/// drawing order, the topmost dialog's spec id, typed text and private row-id parts only through the injected
/// hash, at most ten palette rows, typed hover targets, the owners' change signal for `wait_for`, and
/// not-comparable with its task when the host has no owners to read. Run: `swift test --filter OracleOverlaysFacetTests`.
@MainActor
struct OracleOverlaysFacetTests {
    /// Marks hashed text, so a test sees the text went through the hash and never in raw.
    nonisolated static func hash(_ text: String) -> String { "hashed(\(text.count))" }

    private func overlays(_ reading: OracleOverlaysFacet.Reading) throws -> OracleValue {
        let facet = OracleOverlaysFacet(hash: Self.hash) { reading }
        return try #require(try OracleFacets([facet]).beginCapture([.overlays]).completed?["overlays"])
    }

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
            windows: [.init(window: "win_1", findBars: 1, panels: [.palette]), .init(window: nil, hosted: [.init(.dialog, name: "cmux.dialog.close")])],
            palette: .init(open: true, mode: "commands", query: "split", rowIDs: (0..<14).map { "action:a\($0)" }, selectedIndex: 2),
            hoverCard: .tab("tab_9"),
            findBar: .init(open: true, pane: "pane_1", query: "error!", matches: 7, selected: 0)
        )
        #expect(try overlays(reading) == [
            "stack": [["kind": "findBar", "window": "win_1"], ["kind": "palette", "window": "win_1"], ["kind": "dialog", "window": nil]],
            "palette": ["open": true, "mode": "commands", "querySha256": "hashed(5)",
                        "topIds": .array((0..<10).map { .string("action:a\($0)") }), "selectedIndex": 2],
            "dialog": ["specId": "cmux.dialog.close"],
            "hoverCard": ["target": "tab_9"],
            "findBar": ["open": true, "pane": "pane_1", "querySha256": "hashed(6)", "matches": 7, "selected": 0],
        ])
    }

    /// Each window draws its find bars inside the content, then its overlay host's layers in the host's order, then
    /// its focus panels in open order, then the hover card; windows go in order, the layers no window owns last.
    @Test func eachWindowsLayersGoInTheirDrawingOrder() {
        let reading = OracleOverlaysFacet.Reading(windows: [
            .init(window: "win_1", findBars: 2, hosted: [.init(.toast, name: "saved"), .init(.dialog, name: "a")],
                  panels: [.sheet, .palette], hoverCard: true),
            .init(window: "win_2", hosted: [.init(.popover), .init(.refusalHud, name: "refusal")]),
            .init(window: nil, hosted: [.init(.dialog, name: "quit")]),
        ])
        #expect(reading.stack == [
            .init(.findBar, window: "win_1"), .init(.findBar, window: "win_1"), .init(.toast, window: "win_1"),
            .init(.dialog, window: "win_1"), .init(.sheet, window: "win_1"), .init(.palette, window: "win_1"),
            .init(.hoverCard, window: "win_1"), .init(.popover, window: "win_2"), .init(.refusalHud, window: "win_2"),
            .init(.dialog, window: nil),
        ])
        #expect(reading.dialogSpecID == "quit")
    }

    /// `dialog.specId` names the topmost dialog on the stack, never one that is not on it.
    @Test func theDialogSpecIsTheTopmostDialogsOnTheStack() {
        let twoDialogs = OracleOverlaysFacet.Reading(windows: [.init(window: "win_1", hosted: [.init(.dialog, name: "below"), .init(.dialog, name: "above")])])
        #expect(twoDialogs.dialogSpecID == "above")
        let reversed = OracleOverlaysFacet.Reading(windows: [.init(window: "win_1", hosted: [.init(.dialog, name: "above"), .init(.dialog, name: "below")])])
        #expect(reversed.dialogSpecID == "below")
        // A toast's name is no dialog spec.
        #expect(OracleOverlaysFacet.Reading(windows: [.init(window: "win_1", hosted: [.init(.toast, name: "saved")])]).dialogSpecID == nil)
        // The topmost dialog has no spec id: none is reported, not the one below it.
        let unnamed = OracleOverlaysFacet.Reading(windows: [.init(window: "win_1", hosted: [.init(.dialog, name: "below"), .init(.dialog)])])
        #expect(unnamed.dialogSpecID == nil)
    }

    /// A row id whose payload is a path, URL or name goes in as its kind and the hash of the rest: never raw, and
    /// the same on every machine. Action, tab and setting ids stay as they are.
    @Test func pathBearingRowIDsNeverGoInRaw() throws {
        let ids = ["action:workspace.new", "tab:tab_9", "option:sidebar.style:rail", "path:/Users/me/src",
                   "loc:0:/Users/me/Desktop", "directory:/private/var/folders/x", "open:https://example.com/a", "mail:me@example.com",
                   "rename-workspace:My Project", "/Users/me/notes.md", "commandPalette"]
        let value = try overlays(.init(palette: .init(open: true, rowIDs: ids)))
        #expect(value["palette"]?["topIds"] == [
            "action:workspace.new", "tab:tab_9", "option:sidebar.style:rail", "path:hashed(13)",
            "loc:hashed(19)", "directory:hashed(22)", "open:hashed(21)", "mail:hashed(14)",
            "rename-workspace:hashed(10)", "hashed(18)",
        ])
        #expect(OracleOverlaysFacet.stableRowID("commandPalette", hash: Self.hash) == "commandPalette")
        #expect(OracleOverlaysFacet.stableRowID("scope:", hash: Self.hash) == "scope:")
    }

    @Test func aHoverTargetIsItsItemsID() throws {
        #expect(OracleOverlaysFacet.HoverTarget.workspace("ws_1").id == "ws_1")
        #expect(OracleOverlaysFacet.HoverTarget.group("grp_3").id == "grp_3")
        #expect(OracleOverlaysFacet.HoverTarget.tab("tab_9").id == "tab_9")
        #expect(try overlays(.init(hoverCard: .workspace("ws_1")))["hoverCard"] == ["target": "ws_1"])
    }

    @Test func noOwnersIsNotComparable() throws {
        let facet = OracleOverlaysFacet(hash: Self.hash) { nil }
        let snapshot = try #require(try OracleFacets([facet]).beginCapture([.overlays]).completed)
        #expect(snapshot["overlays"]?["status"] == "not-comparable")
        #expect(snapshot["overlays"]?["task"] == "p15-oracle-038")
    }

    /// The owners' change signal is the facet's.
    @Test func theOwnersChangeSignalIsTheFacets() async throws {
        let (stream, signal) = AsyncStream<Void>.makeStream()
        let facet = OracleOverlaysFacet(hash: Self.hash, changes: { stream }) { OracleOverlaysFacet.Reading() }
        let facets = OracleFacets([facet])
        let changes = try #require(facets.changes(.overlays))
        signal.yield()
        var iterator = changes().makeAsyncIterator()
        #expect(await iterator.next() != nil)
    }

    /// Every kind the facet can name is one the schema's `stack[*].kind` enum lists.
    @Test func theKindsAreTheSchemas() {
        #expect(OracleOverlaysFacet.Kind.allCases.map(\.rawValue)
            == ["palette", "dialog", "hoverCard", "findBar", "popover", "menu", "sheet", "toast", "refusalHud"])
    }
}
#endif
