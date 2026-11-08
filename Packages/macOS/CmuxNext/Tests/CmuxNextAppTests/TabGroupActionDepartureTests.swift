import CmuxNextActions
import CmuxNextBridge
@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextTabs
import CmuxNextTestSupport
import Foundation
import Testing

/// Review follow-up F4 on #37735: the tab-group actions that take a group out of its pane (Move to
/// New Split, New Column, another workspace: the palette, the menu, the CLI) mark its tabs as leaving
/// by a move, as a drag does (`TabMoves.depart`), so their strip drops them with no close. Run against a
/// same-tree cmux-tui: the actions refuse with no daemon.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"), .closesItsWindows)
struct TabGroupActionDepartureTests {
    @Test(arguments: ["tabGroup.moveToNewSplit", "tabGroup.moveToNewColumn", "tabGroup.moveToWorkspace"] as [ActionID])
    func aGroupActionMarksItsTabsDeparting(_ action: ActionID) async throws {
        try await AppHarnessWindows.withApp { services, connection in
            let pane = try MoveToNewWindowTests.firstPane(services)
            let browser = try await MoveToNewWindowTests.browserTab(in: pane, services, connection)
            #expect(services.registry.perform("tabGroup.create", invocation: MoveToNewWindowTests.on(.tab, browser.id)))
            try await PinnedPageTests.until({ services.daemon.store.tab(surface: browser.surface)?.tabGroup != nil })
            let group = try #require(browser.tabGroup)
            var invocation = MoveToNewWindowTests.on(.tabGroup, group.rawValue)
            if action == "tabGroup.moveToWorkspace" {
                let other = try await MoveToNewWindowTests.newWorkspace(services)
                invocation = ActionInvocation(target: invocation.target, arguments: ["workspace": .target(ActionTargetRef(kind: .workspace, id: other.id))])
            }
            let strip = try #require(services.paneController(for: pane), "no controller shows the group's pane").stripModel
            #expect(services.registry.perform(action, invocation: invocation))
            // In the action's turn, before its command replies.
            #expect(strip.departures.contains(StripTabID(browser.id)), "\(action) left the group's tab to close in its strip")
        }
    }
}
