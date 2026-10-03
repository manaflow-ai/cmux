import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextPalette
import CmuxNextSettings
import Testing

/// `palette.run` forwards to `action.run` (palette-scopes.md 6.10): the
/// caller's args merge over the row's, the caller's origin, focus, wait
/// and idempotency key pass through, and the row's target always wins.
@Suite struct PaletteRunParamsTests {
    let ref = PaletteActionRef("palette.toggleSetting", arguments: ["setting": .string("sidebar.minimal"), "on": .bool(true)])

    @Test func callerArgumentsMergeOverTheRows() {
        let params = PaletteScopeControl.actionRunParams(ref, ["args": ["on": false]])
        #expect(params["action"] == "palette.toggleSetting")
        #expect(params["args"] == ["setting": "sidebar.minimal", "on": false])
        #expect(params["target"] == nil)
        #expect(params["origin"] == "cli")
    }

    /// A socket caller cannot claim to be the in-app user (who may move
    /// focus without `focus: true`).
    @Test func theUserOriginIsRefused() throws {
        #expect(throws: (any Error).self) { try PaletteScopeControl.runParameters(["scope": "tabs", "item": "tab:1", "origin": "user"]) }
        #expect(throws: (any Error).self) { try PaletteScopeControl.runParameters(["scope": "tabs", "item": "tab:1", "origin": 3]) }
        for origin in ["cli", "mcp", "script", "remote"] {
            _ = try PaletteScopeControl.runParameters(["scope": "tabs", "item": "tab:1", "origin": .string(origin)])
        }
    }

    @Test func originFocusAndKeyPassThroughAndTheRowTargetWins() {
        let tab = PaletteActionRef("tab.focus", target: ActionTargetRef(kind: .tab, id: "tab_2"))
        let params = PaletteScopeControl.actionRunParams(tab, [
            "origin": "mcp", "focus": true, "wait": false, "idempotency_key": "k1", "target": "tab:other", "scope": "tabs",
        ])
        #expect(params["target"] == "tab:tab_2")
        #expect(params["origin"] == "mcp")
        #expect(params["focus"] == true)
        #expect(params["wait"] == false)
        #expect(params["idempotency_key"] == "k1")
        #expect(params["scope"] == nil)
    }

    @Test func runParametersNeedScopeAndItem() throws {
        #expect(throws: (any Error).self) { try PaletteScopeControl.runParameters(["scope": "tabs"]) }
        #expect(throws: (any Error).self) { try PaletteScopeControl.runParameters(["scope": "tabs", "item": "tab:1", "args": "x"]) }
        let parsed = try PaletteScopeControl.runParameters(["scope": "tabs", "item": "tab:1", "action": "closeTab"])
        #expect(parsed.scope == "tabs" && parsed.item == "tab:1" && parsed.action == "closeTab")
    }
}
