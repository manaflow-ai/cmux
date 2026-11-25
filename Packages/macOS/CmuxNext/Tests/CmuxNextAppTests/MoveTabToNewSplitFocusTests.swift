import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextFocus
import CmuxNextTerminal
import Foundation
import Testing

/// Dogfood v2.1 (b76052722530): a tab moved to a new pane showed there while its old pane's strip still listed it,
/// until that pane's own strip observation ran a main-actor job later. The topology sent with the new pane had the
/// tab in both panes, so focus waited for it to leave the old pane, resolved the old pane to an empty pane, and the
/// window was the first responder in between: keys typed then were lost. Home's dock no longer shows this
/// (feat's OutboundTab keeps a tab the dock makes out of the dock's strip, `HomeDockNewTerminalFocusTests`), but
/// Move Tab to New Split moves a tab that its pane already shows, with no such hold.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct MoveTabToNewSplitFocusTests {
    /// What the window's focus did during the move.
    private final class Record {
        /// The first topology that lists the moved tab in a pane other than its old one, and the focused pane right
        /// after it.
        var firstWithMovedTab: (topology: FocusTopology, focusedAfter: String?)?
        /// Every pane focus resolved to an empty pane.
        var emptyPanes: [String] = []
    }

    /// The topology that first shows the moved terminal in its new split no longer lists it in its old pane, focus
    /// follows it in that reduction (one turn, one topology), and focus never resolves to an empty pane on the way.
    @Test func aTabMovedToANewSplitHasTheKeyboardInTheTurnItShowsThere() async throws {
        try await PasswordManagerRouteTests.withApp { services, connection in
            let window = try #require(services.windows.active)
            let workspace = try await MoveToNewWindowTests.newWorkspace(services)
            window.state.showWorkspace(workspace.id)
            let source = try #require(workspace.screens.first?.panes.first)
            let sourceKey = source.id
            let created = try await connection.newTab(in: source.handle)
            try await PasswordManagerRouteTests.until({
                window.state.workspaceID == workspace.id && source.tabs.count == 2
                    && services.daemon.store.tab(surface: created.surface) != nil
                    && window.focusedPane?.pane === source && window.window?.firstResponder is TerminalSurfaceView
            }, report: {
                "shows \(String(describing: window.state.workspaceID)), tabs \(source.tabs.count), "
                    + "focused \(String(describing: window.focusedPane?.paneKey)), responder \(String(describing: window.window?.firstResponder))"
            })
            let moved = try #require(services.daemon.store.tab(surface: created.surface))
            let movedID = moved.id
            let record = Record()
            let focus = window.focus
            let previous = focus.observer
            focus.observer = { observation in
                previous?(observation)
                guard case .reduced(let event, _, let after, _) = observation else { return }
                if case .emptyPane(let pane) = after.resolved { record.emptyPanes.append(pane) }
                if case .topology(let topology) = event, record.firstWithMovedTab == nil,
                   topology.panes.contains(where: { $0.id != sourceKey && $0.tabs.contains { $0.id == movedID } }) {
                    record.firstWithMovedTab = (topology, after.pane)
                }
            }
            defer { focus.observer = previous }

            let invocation = ActionInvocation(target: ActionTargetRef(kind: .tab, id: movedID), arguments: ["direction": .string("right")], origin: .user)
            #expect(services.registry.perform("tab.moveToNewSplit", invocation: invocation))
            try await PasswordManagerRouteTests.until({
                let panes = workspace.screens.flatMap(\.panes)
                return panes.count == 2 && source.tabs.count == 1 && window.focusedPane?.pane.tabs.contains { $0.id == movedID } == true
                    && window.window?.firstResponder is TerminalSurfaceView
            }, report: {
                "panes \(workspace.screens.flatMap(\.panes).map { $0.tabs.map(\.id) }), focused \(String(describing: window.focusedPane?.paneKey)), "
                    + "responder \(String(describing: window.window?.firstResponder))"
            })
            let first = try #require(record.firstWithMovedTab, "no topology showed the moved tab in a new pane")
            let target = try #require(first.topology.panes.first { $0.id != sourceKey && $0.tabs.contains { $0.id == movedID } })
            #expect(first.topology.panes.first { $0.id == sourceKey }?.tabs.contains { $0.id == movedID } == false,
                    "the topology that showed the new split still listed the moved tab in its old pane: \(first.topology.panes)")
            #expect(first.focusedAfter == target.id, "focus did not follow the moved tab in that topology's reduction")
            #expect(record.emptyPanes.isEmpty, "focus resolved to an empty pane during the move: \(record.emptyPanes)")
        }
    }
}
