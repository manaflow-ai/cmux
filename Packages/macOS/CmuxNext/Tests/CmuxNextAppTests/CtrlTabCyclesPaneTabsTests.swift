import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextSettings
import Testing

/// Ctrl-Tab / Ctrl-Shift-Tab (Leo 2026-10-12) and Cmd-Shift-] / [ (Lawrence
/// 2026-10-15) cycle the tabs of the focused pane, never workspaces.
/// Switching workspaces keeps its other keys: Ctrl-Cmd-] / [, Cmd-Opt
/// arrows, Ctrl-PageDown / PageUp. Resolved as the key router
/// resolves a key-down, with the app's default bindings, in a terminal and
/// in a browser page.
@MainActor @Suite struct CtrlTabCyclesPaneTabsTests {
    /// The app's catalog and default bindings; the four actions are bound
    /// (a key resolves only to an action the app can run).
    static let registry: ActionRegistry = {
        let registry = ActionRegistry.standard()
        let bound: [ActionID] = ["nextSurface", "prevSurface", "nextSidebarTab", "prevSidebarTab"]
        for id in bound {
            registry.bind(id, invoke: { _ in })
        }
        return registry
    }()

    static func winner(_ keys: String, in surface: String) -> String? {
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
    func workspaceSwitchingKeepsItsOtherKeys(_ surface: String) {
        #expect(Self.winner("ctrl+cmd+rightbracket", in: surface) == "nextSidebarTab")
        #expect(Self.winner("ctrl+cmd+leftbracket", in: surface) == "prevSidebarTab")
        #expect(Self.winner("ctrl+pagedown", in: surface) == "nextSidebarTab")
        #expect(Self.winner("ctrl+pageup", in: surface) == "prevSidebarTab")
    }
}
