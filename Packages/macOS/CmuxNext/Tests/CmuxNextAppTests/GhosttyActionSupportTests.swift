@testable import CmuxNextApp
import CmuxNextTerminal
import Testing

/// GHOSTTY-CONFIG diagnostics: the one table of Ghostty keybind actions cmux
/// does not run (`GhosttyActionSupport.unsupported`), with a reason. Every
/// decoded host action without a route must be listed, so the table cannot
/// drift from `TerminalHostActionRoute`.
@MainActor
struct GhosttyActionSupportTests {
    /// Every host action, with the Ghostty action name it comes from.
    static let decoded: [(String, TerminalHostAction)] = [
        ("new_window", .newWindow), ("new_tab", .newTab), ("close_tab", .closeTab(.this)), ("close_window", .closeWindow),
        ("close_all_windows", .closeAllWindows), ("quit", .quit), ("new_split", .newSplit(.right)), ("goto_split", .gotoSplit(.left)),
        ("resize_split", .resizeSplit(.left, amount: 10)), ("equalize_splits", .equalizeSplits), ("toggle_split_zoom", .toggleSplitZoom),
        ("goto_tab", .gotoTab(.next)), ("move_tab", .moveTab(1)), ("toggle_fullscreen", .toggleFullscreen),
        ("toggle_maximize", .toggleMaximize), ("toggle_command_palette", .toggleCommandPalette), ("inspector", .toggleInspector),
        ("prompt_surface_title", .promptTitle), ("check_for_updates", .checkForUpdates), ("undo", .undo), ("redo", .redo),
        ("toggle_visibility", .toggleVisibility), ("toggle_tab_overview", .toggleTabOverview),
        ("prompt_window_title", .promptWindowTitle), ("set_window_title", .setWindowTitle("t")), ("present_terminal", .presentTerminal),
        ("goto_window", .gotoWindow(next: true)), ("move_tab_to_new_window", .moveTabToNewWindow),
    ]

    @Test func everyUnroutedHostActionIsListedWithAReason() {
        for (name, action) in Self.decoded where TerminalHostActionRoute.route(action) == nil {
            #expect(GhosttyActionSupport.unsupported[name] != nil, "\(name) has no route and no table entry")
        }
    }

    @Test func aRoutedActionIsNotListed() {
        for (name, action) in Self.decoded where TerminalHostActionRoute.route(action) != nil {
            #expect(GhosttyActionSupport.unsupported[name] == nil, "\(name) routes")
        }
    }

    @Test func theAgreedEntries() {
        let table = GhosttyActionSupport.unsupported
        for name in ["inspector", "redo", "toggle_background_opacity", "float_window", "reset_window_size"] {
            #expect(table[name]?.reason == .notApplicable, "\(name)")
        }
        #expect(table["toggle_window_decorations"] == GhosttyUnsupported(.superseded, replacement: "window.titlebar"))
        #expect(table["toggle_quick_terminal"]?.reason == .later)
        #expect(table.count == 7)
    }
}
