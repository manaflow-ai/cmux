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
/// (fleet step 4713f899db201892f1cfe058: 9 to 19 of 30 new tabs lost a key; v1.1 none).
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct HomeDockNewTerminalFocusTests {
    /// What the window's focus did during the move.
    private final class Record {
        /// The first topology that shows the new column's pane, and the focused pane right after it.
        var firstWithNewPane: (topology: FocusTopology, focusedAfter: String?)?
        /// Every pane focus resolved to an empty pane.
        var emptyPanes: [String] = []
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
                if case .topology(let topology) = event, record.firstWithNewPane == nil,
                   topology.panes.contains(where: { $0.id != dockKey && !$0.tabs.isEmpty }) {
                    record.firstWithNewPane = (topology, after.pane)
                }
            }
            defer { focus.observer = previous }
            var invocation = ActionInvocation(target: ActionTargetRef(kind: .pane, id: dock.id), origin: .user)
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
        }
    }
}
