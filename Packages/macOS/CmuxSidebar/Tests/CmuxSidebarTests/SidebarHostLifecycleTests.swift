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
    @Test func replacementFencesAllOldCallbacks() {
        var recovery = CMUXSidebarHostRecovery()
        let old = recovery.begin()
        let current = recovery.begin()
        #expect(!recovery.accepts(old))
        #expect(recovery.accepts(current))
        #expect(recovery.retryDelay(for: old, now: 0) == nil)
    }

    @Test func retriesAreBoundedAndOnlyResetAfterStability() {
        var recovery = CMUXSidebarHostRecovery()
        var token = recovery.begin()
        for delay in [0.5, 2.0, 5.0] {
            #expect(recovery.retryDelay(for: token, now: 0) == delay)
            #expect(recovery.retryDelay(for: token, now: 0) == nil)
            token = recovery.begin()
        }
        recovery.ready(for: token, now: 10)
        #expect(recovery.retryDelay(for: token, now: 39) == nil)
        recovery.ready(for: token, now: 40)
        #expect(recovery.retryDelay(for: token, now: 70) == 0.5)
        token = recovery.begin(resetBudget: true)
        #expect(recovery.retryDelay(for: token, now: 71) == 0.5)
    }
}
