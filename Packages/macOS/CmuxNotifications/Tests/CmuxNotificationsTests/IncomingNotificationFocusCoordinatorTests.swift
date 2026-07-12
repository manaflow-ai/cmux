import Foundation
import Testing
@testable import CmuxNotifications

@MainActor
private final class IncomingNotificationFocusRouterFake: IncomingNotificationFocusRouting {
    var focusSucceeds = true
    var activationSucceeds = true
    private(set) var focusedTargets: [IncomingNotificationFocusTarget] = []
    private(set) var activationCount = 0

    func focusIncomingNotification(_ target: IncomingNotificationFocusTarget) -> Bool {
        focusedTargets.append(target)
        return focusSucceeds
    }

    func activateApplicationForIncomingNotification() -> Bool {
        activationCount += 1
        return activationSucceeds
    }
}

@Suite("Incoming notification focus coordinator")
@MainActor
struct IncomingNotificationFocusCoordinatorTests {
    @Test("disabled policy preserves focus")
    func disabledPolicyPreservesFocus() {
        let router = IncomingNotificationFocusRouterFake()
        let coordinator = makeCoordinator(router: router, isEnabled: false, isApplicationActive: false)

        let outcome = coordinator.focusIfNeeded(target: makeTarget(), isDesktopDeliveryEnabled: true)

        #expect(outcome == .ignored)
        #expect(router.focusedTargets.isEmpty)
        #expect(router.activationCount == 0)
    }

    @Test("active app preserves the current workspace")
    func activeAppPreservesWorkspace() {
        let router = IncomingNotificationFocusRouterFake()
        let coordinator = makeCoordinator(router: router, isEnabled: true, isApplicationActive: true)

        let outcome = coordinator.focusIfNeeded(target: makeTarget(), isDesktopDeliveryEnabled: true)

        #expect(outcome == .ignored)
        #expect(router.focusedTargets.isEmpty)
    }

    @Test("non-desktop notification effects preserve focus")
    func nonDesktopEffectsPreserveFocus() {
        let router = IncomingNotificationFocusRouterFake()
        let coordinator = makeCoordinator(router: router, isEnabled: true, isApplicationActive: false)

        let outcome = coordinator.focusIfNeeded(target: makeTarget(), isDesktopDeliveryEnabled: false)

        #expect(outcome == .ignored)
        #expect(router.focusedTargets.isEmpty)
    }

    @Test("inactive app focuses the exact notification target")
    func inactiveAppFocusesTarget() {
        let router = IncomingNotificationFocusRouterFake()
        let coordinator = makeCoordinator(router: router, isEnabled: true, isApplicationActive: false)
        let target = makeTarget()

        let outcome = coordinator.focusIfNeeded(target: target, isDesktopDeliveryEnabled: true)

        #expect(outcome == .focusedTarget)
        #expect(router.focusedTargets == [target])
        #expect(router.activationCount == 0)
    }

    @Test("missing or failed target activates the fallback window", arguments: [true, false])
    func missingOrFailedTargetActivatesFallback(targetIsMissing: Bool) {
        let router = IncomingNotificationFocusRouterFake()
        router.focusSucceeds = false
        let coordinator = makeCoordinator(router: router, isEnabled: true, isApplicationActive: false)

        let outcome = coordinator.focusIfNeeded(
            target: targetIsMissing ? nil : makeTarget(),
            isDesktopDeliveryEnabled: true
        )

        #expect(outcome == .activatedFallback)
        #expect(router.activationCount == 1)
    }

    @Test("failed fallback reports unavailable")
    func failedFallbackReportsUnavailable() {
        let router = IncomingNotificationFocusRouterFake()
        router.focusSucceeds = false
        router.activationSucceeds = false
        let coordinator = makeCoordinator(router: router, isEnabled: true, isApplicationActive: false)

        let outcome = coordinator.focusIfNeeded(target: makeTarget(), isDesktopDeliveryEnabled: true)

        #expect(outcome == .unavailable)
    }

    private func makeCoordinator(
        router: IncomingNotificationFocusRouterFake,
        isEnabled: Bool,
        isApplicationActive: Bool
    ) -> IncomingNotificationFocusCoordinator {
        IncomingNotificationFocusCoordinator(
            routing: router,
            isEnabled: { isEnabled },
            isApplicationActive: { isApplicationActive }
        )
    }

    private func makeTarget() -> IncomingNotificationFocusTarget {
        IncomingNotificationFocusTarget(
            workspaceId: UUID(),
            surfaceId: UUID(),
            panelId: UUID()
        )
    }
}
