import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextTerminal
import Testing

/// Ghostty keybinds (`new_split`, `goto_split`, `equalize_splits`, ...) reach
/// the app as `TerminalHostAction`s. They must run the same registry actions
/// as the shortcut, menu, palette, and CLI, targeted at the terminal's tab.
@MainActor
struct TerminalHostActionTests {
    final class Recorder { var runs: [(ActionID, ActionTargetRef?)] = [] }

    /// Services with a one-tab tree loaded and `ids` rebound to a recorder.
    private static func services(recording ids: [ActionID]) throws -> (AppServices, TabModel, Recorder) {
        let services = ActionBindingCoverageTests.boundServices()
        services.daemon.store.apply(snapshot: try BridgeTreeFixture.tree())
        let tab = try #require(services.daemon.store.workspaces.first?.screens.first?.panes.first?.tabs.first)
        let recorder = Recorder()
        for id in ids {
            services.registry.bind(id, invoke: { recorder.runs.append((id, $0.target)) })
        }
        return (services, tab, recorder)
    }

    @Test func ghosttyNewSplitRunsTheRegistrySplitOnItsTab() throws {
        let (services, tab, recorder) = try Self.services(recording: ["splitRight"])
        let session = services.cache.terminal(for: tab, daemon: services.daemon).session
        let handled = session.delegate?.terminalSession(session, perform: .newSplit(.right))
        #expect(handled == true)
        #expect(recorder.runs.map(\.0) == ["splitRight"])
        #expect(recorder.runs.first?.1 == ActionTargetRef(kind: .tab, id: tab.id))
    }

    @Test func everySplitKeybindMapsToItsAction() throws {
        let table: [(TerminalHostAction, ActionID)] = [
            (.newSplit(.right), "splitRight"), (.newSplit(.down), "splitDown"),
            (.newSplit(.left), "splitLeft"), (.newSplit(.up), "splitUp"),
            (.gotoSplit(.left), "focusLeft"), (.gotoSplit(.right), "focusRight"),
            (.gotoSplit(.up), "focusUp"), (.gotoSplit(.down), "focusDown"),
            (.gotoSplit(.previous), "focusPreviousPane"), (.gotoSplit(.next), "focusNextPane"),
            (.resizeSplit(.left, amount: 10), "resizePaneLeft"), (.resizeSplit(.right, amount: 10), "resizePaneRight"),
            (.resizeSplit(.up, amount: 10), "resizePaneUp"), (.resizeSplit(.down, amount: 10), "resizePaneDown"),
            (.equalizeSplits, "equalizeSplits"), (.toggleSplitZoom, "toggleSplitZoom"),
        ]
        let (services, tab, recorder) = try Self.services(recording: table.map(\.1))
        let session = services.cache.terminal(for: tab, daemon: services.daemon).session
        for (action, _) in table {
            #expect(session.delegate?.terminalSession(session, perform: action) == true, "\(action)")
        }
        #expect(recorder.runs.map(\.0) == table.map(\.1))
    }

    @Test func terminalRightClickSplitsTheClickedTerminal() throws {
        let (services, tab, recorder) = try Self.services(recording: ["splitDown"])
        let session = services.cache.terminal(for: tab, daemon: services.daemon).session
        let event = try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                    windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        let menu = try #require(session.delegate?.terminalSession(session, contextMenuFor: event))
        // Splits live in the menu's Split submenu.
        let split = try #require(menu.items.first { $0.submenu?.items.contains { $0.title == "Split Down" } == true }?.submenu)
        let index = try #require(split.items.firstIndex { $0.title == "Split Down" })
        split.performActionForItem(at: index)
        #expect(recorder.runs.map(\.0) == ["splitDown"])
        #expect(recorder.runs.first?.1 == ActionTargetRef(kind: .tab, id: tab.id))
    }

    /// Split shortcuts are tier 1: the app-wide interceptor
    /// (`CmuxApplication.sendEvent`) runs them before any window, and the
    /// window's own key equivalent hook (tier 2 only) never runs them again.
    @Test func splitShortcutsRouteAppWideNotInTheWindow() throws {
        let (services, _, recorder) = try Self.services(recording: ["splitRight", "splitDown"])
        let window = ShellWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled],
                                 backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let focus = FocusCoordinator()
        window.keyRouter = services.keyRouter
        window.focus = focus
        var resolved: [ActionID] = []
        for (characters, flags) in [("d", NSEvent.ModifierFlags.command), ("D", [.command, .shift])] {
            let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 1,
                                                      windowNumber: window.windowNumber, context: nil, characters: characters,
                                                      charactersIgnoringModifiers: characters, isARepeat: false, keyCode: 2))
            let candidate = try #require(services.keyRouter.candidate(for: event, focus: FocusReducerTests.loaded()))
            #expect(KeyRouter.intercepts(candidate, focus: FocusReducerTests.loaded(), keyWindow: .content))
            resolved.append(candidate.id)
            #expect(!services.keyRouter.routeContentKeyEquivalent(event, focus: FocusReducerTests.loaded()))
        }
        #expect(resolved == ["splitRight", "splitDown"])
        #expect(recorder.runs.isEmpty)
        withExtendedLifetime(focus) {}
    }

    @Test func terminalRightClickOffersSplits() {
        let ids = ContextMenuCatalog.shared.referencedIDs(ContextMenuCatalog.shared.entries(for: .terminalSelection))
        for id: ActionID in ["splitRight", "splitDown", "splitLeft", "splitUp"] {
            #expect(ids.contains(id), "\(id)")
        }
    }
}
