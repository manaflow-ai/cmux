import ExtensionKit
import Testing
@_spi(CmuxHostTransport) @testable import CmuxSidebar

@Suite @MainActor
struct SidebarHostLifecycleTests {
    @Test func dismantledCoordinatorIgnoresLateDeactivation() {
        var deactivations = 0
        let coordinator = CMUXSidebarExtensionHostView.Coordinator(
            onConnection: nil,
            onDeactivation: { _ in deactivations += 1 },
            onTeardown: nil
        )
        coordinator.teardown()
        coordinator.hostViewControllerWillDeactivate(EXHostViewController(), error: nil)
        #expect(deactivations == 0)
    }

    @Test func teardownIsIdempotent() {
        var teardowns = 0
        let coordinator = CMUXSidebarExtensionHostView.Coordinator(
            onConnection: nil, onDeactivation: nil,
            onTeardown: { teardowns += 1 }
        )
        coordinator.teardown()
        coordinator.teardown()
        #expect(teardowns == 1)
    }
}
