import AppKit
import CmuxNextActions
import Foundation
import Testing
@testable import CmuxNextApp

/// R69 follow-up: Back and Forward show whether the trail has somewhere to
/// go (LocationTrailService.canNavigate), re-read on every trail change.
@MainActor @Suite(.serialized, .timeLimit(.minutes(2))) struct TitlebarHistoryEnabledTests {
    typealias Wiring = LocationTrailWiringTests

    @Test func backAndForwardFollowTheTrail() async throws {
        let services = ActionBindingCoverageTests.boundServices()
        try await Wiring.useEverythingSteps(services)
        services.windows.ordersWindowsIn = false
        services.daemon.store.apply(snapshot: try Wiring.tree(tabs: [7, 8]))
        let controller = try #require(services.windows.openWindow(workspaces: [Wiring.key]))
        services.windows.reconcileMembership()
        defer { controller.window?.close() }
        let pane = try #require(services.daemon.store.workspaces.first?.screens.first?.panes.first)
        let (first, second) = (pane.tabs[0].id, pane.tabs[1].id)
        let trail = services.locationTrail
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        trail.now = { clock }
        let root = controller.root

        await Wiring.settle { controller.focus.state.topology.contains(pane: pane.id) }
        controller.focus.send(.selectTab(pane: pane.id, tab: first, workspace: Wiring.key, source: .mouse))
        await Wiring.settle { trail.trail.current?.location.key.tab == first }
        #expect(!root.historyButtonEnabled(.back) && !root.historyButtonEnabled(.forward))

        clock += 5
        controller.focus.send(.selectTab(pane: pane.id, tab: second, workspace: Wiring.key, source: .mouse))
        await Wiring.settle { trail.trail.entries.count >= 2 }
        #expect(root.historyButtonEnabled(.back) && !root.historyButtonEnabled(.forward))

        clock += 5
        #expect(services.registry.perform("focusHistoryBack"))
        await Wiring.settle { trail.trail.current?.location.key.tab == first }
        #expect(!root.historyButtonEnabled(.back) && root.historyButtonEnabled(.forward))
    }
}
