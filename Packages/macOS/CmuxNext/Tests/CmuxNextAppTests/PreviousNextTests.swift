import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import Testing

/// Previous / Next (Leo 2026-10-09, rapid switching): one pair of commands
/// on the browser-style keys. A focused pane with 2+ tabs steps its tabs,
/// wrapping inside the pane; anything else (a 1-tab pane, the sidebar, a
/// field, nothing) steps the sidebar rows.
@MainActor
struct PreviousNextTests {
    /// Every keyboard target inside a pane with content.
    static let inPane: [FocusState.Resolved] = [
        .terminal(pane: "a", tab: "t"), .browserPage(pane: "a", tab: "t"), .addressBar(pane: "a", tab: "t"),
        .findBar(pane: "a", tab: "t"), .devTools(pane: "a", tab: "t"), .agentPage(pane: "a", tab: "t"),
        .page(pane: "a", tab: "t"), .conversation(pane: "a", tab: "t"),
    ]

    @Test(arguments: [2, 3, 9])
    func aPaneWithTwoOrMoreTabsStepsItsTabs(tabs: Int) {
        for focus in Self.inPane {
            #expect(PreviousNext.scope(for: focus, paneTabs: tabs) == .paneTabs, "\(focus)")
        }
    }

    /// Addendum: a pane with one tab has nothing to switch to, so the keys
    /// go on to the sidebar rows.
    @Test(arguments: [0, 1])
    func aOneTabPaneFallsThroughToTheSidebar(tabs: Int) {
        for focus in Self.inPane + [.emptyPane(pane: "a")] {
            #expect(PreviousNext.scope(for: focus, paneTabs: tabs) == .sidebarRows, "\(focus)")
        }
    }

    /// Outside a pane the keys step the sidebar, even when the window's
    /// focused pane has tabs.
    @Test func outsideAPaneTheKeysStepTheSidebar() {
        for focus: FocusState.Resolved in [.sidebar, .sidebarField, .textField, .none] {
            #expect(PreviousNext.scope(for: focus, paneTabs: 3) == .sidebarRows, "\(focus)")
        }
    }

    /// The browser-style keys run the context-aware pair by default:
    /// Cmd-Shift-] / [ and Ctrl-Tab / Ctrl-Shift-Tab (and Ctrl-PageDown /
    /// PageUp), so a macropad can send either pair.
    @Test func theBrowserStyleKeysRunPreviousAndNext() {
        let registry = KeybindingReportTests.registry()
        let rows = KeybindingReportTests.bindings(KeybindingReports.list([:], registry: registry))
        let pairs: [(Shortcut, ActionID)] = [
            (Shortcut("]", modifiers: [.command, .shift]), "navigate.next"),
            (Shortcut("[", modifiers: [.command, .shift]), "navigate.previous"),
            (Shortcut("\t", modifiers: [.control]), "navigate.next"),
            (Shortcut("\t", modifiers: [.control, .shift]), "navigate.previous"),
            (Shortcut(KeyBindingDefaults.pageDown, modifiers: [.control]), "navigate.next"),
            (Shortcut(KeyBindingDefaults.pageUp, modifiers: [.control]), "navigate.previous"),
        ]
        for (key, command) in pairs {
            let defaults = rows.filter { $0["display"] == .string(key.displayString) && $0["source"] == "default" }
            #expect(defaults.contains { $0["command"] == .string(command.rawValue) }, "\(key.displayString) runs \(command)")
            #expect(!defaults.contains { $0["command"] == "nextSurface" || $0["command"] == "prevSurface" },
                    "\(key.displayString) no longer runs the pane-only command")
        }
    }

    /// The explicit commands stay, without the browser keys: Next/Previous
    /// Tab in Pane (`nextSurface`, the CLI's `tab next`) and Next/Previous
    /// Workspace (`nextSidebarTab`, Ctrl-Cmd-] / [).
    @Test func theExplicitCommandsStay() {
        let registry = ActionRegistry.standard()
        for id: ActionID in ["navigate.next", "navigate.previous", "nextSurface", "prevSurface", "nextSidebarTab", "prevSidebarTab"] {
            #expect(registry.descriptor(for: id)?.surfaces.contains(.palette) == true, "\(id) is in the palette")
        }
        #expect(registry.descriptor(for: "nextSidebarTab")?.defaultShortcut == Shortcut("]", modifiers: [.control, .command]))
        #expect(registry.descriptor(for: "nextSurface")?.defaultShortcut == nil)
    }

    /// A terminal's Ctrl-Tab is Ghostty's `next_tab` keybind; it runs the
    /// same pair, so the user's Ghostty config still decides (unbound
    /// there, the key reaches the program in the terminal).
    @Test func ghosttysTabKeybindsRunPreviousAndNext() {
        #expect(TerminalHostActionRoute.route(.gotoTab(.next))?.id == "navigate.next")
        #expect(TerminalHostActionRoute.route(.gotoTab(.previous))?.id == "navigate.previous")
    }
}
