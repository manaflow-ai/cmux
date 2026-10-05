import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextTerminal
import Testing

/// GHOSTTY-CONFIG (plans/cmux-next/ghostty-config.md "Keybinds"): Ghostty
/// actions route to the cmux action catalog. A route makes the keybind run
/// the same action as cmux's shortcut, menu and palette, in a terminal and
/// (as a binding table entry) app-wide.
@MainActor
struct TerminalHostRouteFillTests {
    @Test func appActionsRouteToTheirCatalogActions() {
        #expect(TerminalHostActionRoute.route(.quit)?.id == "quit")
        #expect(TerminalHostActionRoute.route(.checkForUpdates)?.id == "palette.checkForUpdates")
        // Ghostty's `undo` restores the last closed tab, split or window.
        #expect(TerminalHostActionRoute.route(.undo)?.id == "history.reopen")
        #expect(TerminalHostActionRoute.route(.toggleVisibility)?.id == "showHideAllWindows")
        #expect(TerminalHostActionRoute.route(.toggleTabOverview)?.id == "tab.search")
    }

    /// Titles: a surface or tab prompt renames the tab; a window prompt or
    /// `set_window_title` renames the workspace (cmux's window title comes
    /// from it), in whatever workspace is active, not the terminal's tab.
    @Test func titleActionsRouteToRenames() {
        #expect(TerminalHostActionRoute.route(.promptTitle)?.id == "renameTab")
        let prompt = TerminalHostActionRoute.route(.promptWindowTitle)
        #expect(prompt?.id == "renameWorkspace")
        #expect(prompt?.targetsTerminal == false)
        let set = TerminalHostActionRoute.route(.setWindowTitle("build"))
        #expect(set?.id == "renameWorkspace")
        #expect(set?.arguments["name"] == .string("build"))
        #expect(set?.targetsTerminal == false)
    }

    /// `present_terminal` shows that terminal's tab.
    @Test func presentTerminalShowsItsTab() {
        let route = TerminalHostActionRoute.route(.presentTerminal)
        #expect(route?.id == "tab.focus")
        #expect(route?.targetsTerminal == true)
    }

    /// Each routed target is a real catalog action.
    @Test func everyNewRouteNamesACatalogAction() {
        let registry = ActionRegistry.standard()
        for action: TerminalHostAction in [.quit, .checkForUpdates, .undo, .toggleVisibility, .toggleTabOverview, .promptWindowTitle,
                                           .setWindowTitle("x"), .presentTerminal] {
            let id = TerminalHostActionRoute.route(action)?.id
            #expect(id.map { registry.descriptor(for: $0) != nil } == true, "\(action)")
        }
    }

    /// The keybinds become binding table entries (the routable list the
    /// Ghostty config is read with).
    @Test func theNewActionsAreReadFromTheGhosttyConfig() {
        let names = GhosttyHostKeybind.routableNames
        for name in ["quit", "check_for_updates", "undo", "toggle_visibility", "toggle_tab_overview", "prompt_surface_title",
                     "prompt_window_title"] {
            #expect(names.contains(name), "\(name)")
        }
    }
}
