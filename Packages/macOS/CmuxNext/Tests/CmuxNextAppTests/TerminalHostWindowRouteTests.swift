import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextTerminal
import Testing

/// GHOSTTY-CONFIG item (c), the window actions cmux adds to its catalog
/// (coordinator decisions A1, B1, D1, E1): close_all_windows,
/// toggle_maximize, goto_window and move_tab_to_new_window route to catalog
/// actions that are bound.
@MainActor
struct TerminalHostWindowRouteTests {
    static let expected: [(TerminalHostAction, ActionID)] = [
        (.closeAllWindows, "closeAllWindows"), (.toggleMaximize, "zoomWindow"),
        (.gotoWindow(next: true), "selectNextWindow"), (.gotoWindow(next: false), "selectPreviousWindow"),
        (.moveTabToNewWindow, "tab.moveToNewWindow"),
    ]

    @Test func windowActionsRouteToTheirCatalogActions() {
        for (action, id) in Self.expected {
            #expect(TerminalHostActionRoute.route(action)?.id == id, "\(action)")
        }
    }

    @Test func theRoutedActionsAreBoundCatalogActions() {
        let services = ActionBindingCoverageTests.boundServices()
        for (_, id) in Self.expected {
            #expect(services.registry.descriptor(for: id) != nil, "\(id) in the catalog")
            #expect(services.registry.isBound(id), "\(id) has a handler")
        }
    }

    @Test func theWindowActionsAreReadFromTheGhosttyConfig() {
        for name in ["close_all_windows", "toggle_maximize", "goto_window:next", "goto_window:previous", "move_tab_to_new_window"] {
            #expect(GhosttyHostKeybind.routableNames.contains(name), "\(name)")
        }
    }
}
