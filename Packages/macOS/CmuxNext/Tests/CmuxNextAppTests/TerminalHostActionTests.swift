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
        let session = services.cache.terminal(for: tab).session
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
        let session = services.cache.terminal(for: tab).session
        for (action, _) in table {
            #expect(session.delegate?.terminalSession(session, perform: action) == true, "\(action)")
        }
        #expect(recorder.runs.map(\.0) == table.map(\.1))
    }

    @Test func terminalRightClickOffersSplits() {
        let ids = ContextMenuCatalog.referencedIDs(ContextMenuCatalog.entries(for: .terminalSelection))
        for id: ActionID in ["splitRight", "splitDown", "splitLeft", "splitUp"] {
            #expect(ids.contains(id), "\(id)")
        }
    }
}
