import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextFocus
import CmuxNextTerminal
import Foundation
import Testing

/// Dogfood v2.1 (Lawrence 2026-10-27: "new terminals when i type in it feels laggy"): a new terminal asked for from
/// Home's dock is made there and moved to a column right of it. The workspace's layout showed it in the new column,
/// but the dock's strip still listed it until the dock pane's own observation ran a main-actor job later, so the
/// topology sent with the new column had the tab in both panes: focus waited, resolved the dock to an empty pane,
/// the window was the first responder for ~20-30 ms, and the first keys typed into the new terminal were lost
/// (fleet step 4713f899db201892f1cfe058: 9 to 19 of 30 new tabs lost a key; v1.1 none). Second window: the move's focus
/// expectation was set only by the move's reply completion, up to ~230 ms after the delta showed the new column, so
/// focus fell back to Home's page in the dock meanwhile (fleet step c301b08a6735a4f28d8bf832).
/// skip-owner: PL-typing; expiry: 2026-11-06; tracking: handoff/followups.md "skips audit 2026-10-30"
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct HomeDockNewTerminalFocusTests {
    /// What the window's focus did during the move.
    private final class Record {
        /// The first topology that shows the new column's pane, and the focused pane right after it.
        var firstWithNewPane: (topology: FocusTopology, focusedAfter: String?)?
        /// Every pane focus resolved to an empty pane.
        var emptyPanes: [String] = []
        /// What focus resolved to in Home's dock after the new column showed (the keys would go there).
        var backInDock: [String] = []
    }

    /// The topology that first shows the moved terminal in its new column lands the focus there in the same
    /// reduction (one turn, one topology), and focus never resolves to an empty pane on the way.
    @Test func aNewTerminalFromHomesDockHasTheKeyboardInTheTurnItShowsBesideIt() async throws {
        try await PasswordManagerRouteTests.withApp { services, connection in
            let (window, home) = try await HomeSplitKeysTests.showHome(services, connection)
            let dock = try #require(HomeSplitKeysTests.panes(home).first)
            let dockKey = dock.id
            let record = Record()
            let focus = window.focus
            let previous = focus.observer
            focus.observer = { observation in
                previous?(observation)
                guard case .reduced(let event, _, let after, _) = observation else { return }
                if case .emptyPane(let pane) = after.resolved { record.emptyPanes.append(pane) }
                if record.firstWithNewPane != nil, after.pane == dockKey { record.backInDock.append(after.resolved.kind) }
                if case .topology(let topology) = event, record.firstWithNewPane == nil,
                   topology.panes.contains(where: { $0.id != dockKey && !$0.tabs.isEmpty }) {
                    record.firstWithNewPane = (topology, after.pane)
                }
            }
            defer { focus.observer = previous }
            // A script's (or the CLI's) new terminal with focus, as the perf lab's first-keys check sends it: it is made in
            // the dock and moved beside it (HomeDockOpens.placing -> LinkOpener.moveBeside). A person's own new terminal
            // from a lone dock opens its column directly (ChatColumnPlacement.besideDock) and is not this path.
            var invocation = ActionInvocation(target: ActionTargetRef(kind: .pane, id: dock.id), origin: .script, focusRequested: true)
            invocation.opensTerminal = true
            #expect(services.registry.perform("newSurface", invocation: invocation))
            try await PasswordManagerRouteTests.until({
                let panes = HomeSplitKeysTests.panes(home)
                return panes.count == 2 && dock.tabs.count == 1 && window.focusedPane?.pane === panes.last
                    && window.window?.firstResponder is TerminalSurfaceView
            }, report: {
                "panes \(HomeSplitKeysTests.panes(home).map { $0.tabs.map { "\($0.kind)" } }), focused \(String(describing: window.focusedPane?.paneKey)), "
                    + "responder \(String(describing: window.window?.firstResponder))"
            })
            let first = try #require(record.firstWithNewPane, "no topology showed the new column")
            let moved = try #require(first.topology.panes.first { $0.id != dockKey })
            #expect(first.topology.panes.first { $0.id == dockKey }?.tabs.contains { moved.tabs.map(\.id).contains($0.id) } == false,
                    "the topology that showed the new column still listed the moved terminal in Home's dock: \(first.topology.panes)")
            #expect(first.focusedAfter == moved.id, "focus did not follow the moved terminal in that topology's reduction")
            #expect(record.emptyPanes.isEmpty, "focus resolved to an empty pane during the move: \(record.emptyPanes)")
            #expect(record.backInDock.isEmpty, "focus went back to Home's dock after the new column showed: \(record.backInDock)")
        }
    }
}
