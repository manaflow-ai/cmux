import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDesign
import CmuxNextSettings
import Testing

@MainActor @Suite(.serialized) struct SidebarEmptyWorkspaceShortcutTests {
    @Test func sidebarShortcutProjectionFollowsSettings() {
        let registry = ActionRegistry.standard()
        for descriptor in ActionCatalog.all { registry.bind(descriptor.id) {} }
        let applier = SettingsApplier(design: DesignSettings(), registry: registry)
        let cases: [(JSONValue, String?)] = [
            ([:], "⌘N"),
            (["tabs": ["swapCmdTAndCmdN": true]], "⌘T"),
            (["shortcuts": ["bindings": ["newTab": "cmd+shift+k"]]], "⇧⌘K"),
            (["shortcuts": ["bindings": ["newTab": []]]], nil),
            ([:], "⌘N"),
        ]
        for (config, expected) in cases {
            applier.apply(CmuxConfigSnapshot.parse(config, validDensities: [], validMetrics: []))
            #expect(registry.shortcutDisplay(for: "newTab") == expected)
            #expect(SidebarBridge.builtInShortcuts(registry)["newTab"] == expected)
        }
    }
}
