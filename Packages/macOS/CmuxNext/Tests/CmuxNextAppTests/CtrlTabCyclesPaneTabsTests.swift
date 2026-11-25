import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextSettings
import Testing

/// Ctrl-Tab / Ctrl-Shift-Tab (Leo 2026-10-12) and Cmd-Shift-] / [ (Lawrence
/// 2026-10-15) cycle the tabs of the focused pane, never workspaces.
/// Switching workspaces keeps Ctrl-Cmd-] / [. Cmd-Opt arrows focus panes, as
/// Ghostty's `goto_split` defaults, and Ctrl-PageDown / PageUp have no cmux
/// default (Lawrence 2026-10-20). A user's Ghostty keybind wins over every
/// one of these defaults. Resolved as the key router resolves a key-down,
/// with the app's default bindings, in a terminal and in a browser page.
@MainActor @Suite struct CtrlTabCyclesPaneTabsTests {
    static let bound: [ActionID] = [
        "nextSurface", "prevSurface", "nextSidebarTab", "prevSidebarTab", "focusLeft", "focusRight", "newSurface",
    ]

    /// The app's catalog and default bindings; the actions above are bound
    /// (a key resolves only to an action the app can run).
    static func makeRegistry() -> ActionRegistry {
        let registry = ActionRegistry.standard()
        for id in bound {
            registry.bind(id, invoke: { _ in })
        }
        return registry
    }

    static let registry = makeRegistry()

    static func winner(_ keys: String, in surface: String, registry: ActionRegistry = Self.registry) -> String? {
        let context = KeyContext([KeyContext.surfaceKind: .string(surface)])
        guard case .object(let report)? = KeybindingReports.resolve(keys, context: context, registry: registry, window: nil),
              report["outcome"]?.stringValue == "run", case .object(let winner)? = report["winner"] else { return nil }
        return winner["command"]?.stringValue
    }

    @Test(arguments: ["terminal", "browser"])
    func ctrlTabCyclesTheFocusedPanesTabs(_ surface: String) {
        #expect(Self.winner("ctrl+tab", in: surface) == "nextSurface")
        #expect(Self.winner("ctrl+shift+tab", in: surface) == "prevSurface")
        #expect(Self.winner("cmd+shift+rightbracket", in: surface) == "nextSurface")
        #expect(Self.winner("cmd+shift+leftbracket", in: surface) == "prevSurface")
    }

    @Test(arguments: ["terminal", "browser"])
    func workspaceSwitchingKeepsCtrlCmdBrackets(_ surface: String) {
        #expect(Self.winner("ctrl+cmd+rightbracket", in: surface) == "nextSidebarTab")
        #expect(Self.winner("ctrl+cmd+leftbracket", in: surface) == "prevSidebarTab")
    }

    @Test(arguments: ["terminal", "browser"])
    func cmdOptArrowsFocusPanesAndCtrlPageKeysAreFree(_ surface: String) {
        #expect(Self.winner("cmd+opt+left", in: surface) == "focusLeft")
        #expect(Self.winner("cmd+opt+right", in: surface) == "focusRight")
        #expect(Self.winner("ctrl+pagedown", in: surface) == nil)
        #expect(Self.winner("ctrl+pageup", in: surface) == nil)
    }

    /// A keybind the user's Ghostty config changed (`.ghostty`) wins over the
    /// cmux default on the same key; before, the tab keys sat above it.
    @Test func usersGhosttyKeybindWinsOverTheTabKeys() {
        let registry = Self.makeRegistry()
        let ctrlTab = Shortcut("\t", modifiers: [.control])
        let cmdOptLeft = Shortcut(Shortcut.leftArrowKey, modifiers: [.command, .option])
        KeyBindingLoader(registry).loadGhostty([
            KeyBinding(keys: [ctrlTab], command: "newSurface", source: .ghostty),
            KeyBinding(keys: [cmdOptLeft], command: "prevSidebarTab", source: .ghostty),
        ])
        #expect(Self.winner("ctrl+tab", in: "terminal", registry: registry) == "newSurface")
        #expect(Self.winner("cmd+opt+left", in: "terminal", registry: registry) == "prevSidebarTab")
    }
}
