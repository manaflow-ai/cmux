import CmuxNextSettings
import Testing

/// `newTerminal.opensWorkspace`: a click on a New Terminal control (the strip's +, the sidebar)
/// makes a workspace while it is on, Option reversing it for that click. New Terminal Tab's key
/// (Ctrl-`) always opens the terminal in the focused workspace. Before, with the setting on,
/// Ctrl-` made a whole new workspace (https://github.com/manaflow-ai/cmux/issues/34431). The
/// handler passes `byKey` from `ActionRegistry.isDispatchingKeyDown`, which a key the router
/// runs sets (InputDispatchAgeTests).
struct NewTerminalWorkspaceSettingTests {
    private static func setting(_ json: JSONValue) -> Bool {
        CmuxConfigSnapshot.parse(json, validDensities: [], validMetrics: []).newTerminalOpensWorkspace
    }

    @Test func theKeyOpensATabWithTheSettingOn() {
        let on = Self.setting(.object(["newTerminal": .object(["opensWorkspace": .bool(true)])]))
        #expect(on)
        #expect(!NewTerminalWorkspaceSetting.opensWorkspace(setting: on, toggled: false, byPerson: true, byKey: true),
                "Ctrl-` made a new workspace with newTerminal.opensWorkspace on")
        #expect(!NewTerminalWorkspaceSetting.opensWorkspace(setting: on, toggled: true, byPerson: true, byKey: true))
    }

    @Test func theControlsFollowTheSetting() {
        let on = Self.setting(.object(["newTerminal": .object(["opensWorkspace": .bool(true)])]))
        #expect(NewTerminalWorkspaceSetting.opensWorkspace(setting: on, toggled: false, byPerson: true, byKey: false))
        // Option-click reverses it, either way.
        #expect(!NewTerminalWorkspaceSetting.opensWorkspace(setting: on, toggled: true, byPerson: true, byKey: false))
        #expect(NewTerminalWorkspaceSetting.opensWorkspace(setting: false, toggled: true, byPerson: true, byKey: false))
        // Off by default: a tab.
        #expect(!NewTerminalWorkspaceSetting.opensWorkspace(setting: Self.setting(.object([:])), toggled: false, byPerson: true, byKey: false))
    }

    @Test func aScriptNeverMakesAWorkspace() {
        #expect(!NewTerminalWorkspaceSetting.opensWorkspace(setting: true, toggled: false, byPerson: false, byKey: false))
    }
}
