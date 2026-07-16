#if canImport(AppKit)

import AppKit
import Testing
@testable import CmuxAppKitSupportUI

@Suite struct ArrowlessPopoverRootViewUpdatePolicyTests {
    @Test func hiddenClosedPopoverDoesNotNeedHostedRootRefresh() {
        #expect(ArrowlessPopoverRootViewUpdatePolicy.rootViewUpdateStrategy(
            isPresented: false,
            popoverIsShown: false
        ) == .none)
    }

    @Test func firstPresentationUpdatesHostedRootSynchronously() {
        #expect(ArrowlessPopoverRootViewUpdatePolicy.rootViewUpdateStrategy(
            isPresented: true,
            popoverIsShown: false
        ) == .immediate)
    }

    @Test func visiblePopoverDefersHostedRootRefreshOutsideRepresentableUpdate() {
        #expect(ArrowlessPopoverRootViewUpdatePolicy.rootViewUpdateStrategy(
            isPresented: false,
            popoverIsShown: true
        ) == .deferredVisible)
        #expect(ArrowlessPopoverRootViewUpdatePolicy.rootViewUpdateStrategy(
            isPresented: true,
            popoverIsShown: true
        ) == .deferredVisible)
    }
}

@MainActor
@Suite struct CmuxPopoverVisibleUpdateSchedulerTests {
    @Test func visibleUpdatesRunAfterCurrentMainActorTurnAndCoalesce() async {
        let scheduler = CmuxPopoverVisibleUpdateScheduler()
        var applied: [String] = []

        scheduler.schedule { applied.append("first") }
        scheduler.schedule { applied.append("second") }

        #expect(applied.isEmpty)
        await Task.yield()
        #expect(applied == ["second"])
    }

    @Test func cancellationDropsPendingVisibleUpdate() async {
        let scheduler = CmuxPopoverVisibleUpdateScheduler()
        var applied = false

        scheduler.schedule { applied = true }
        scheduler.cancel()

        await Task.yield()
        #expect(applied == false)
    }

    @Test func cancelledTaskDoesNotClearRescheduledVisibleUpdate() async {
        let scheduler = CmuxPopoverVisibleUpdateScheduler()
        var applied: [String] = []

        scheduler.schedule { applied.append("cancelled") }
        scheduler.cancel()
        scheduler.schedule { applied.append("rescheduled") }

        await Task.yield()
        await Task.yield()
        #expect(applied == ["rescheduled"])
    }
}

@MainActor
@Suite struct CmuxPopoverMutationTests {
    @Test func animationContextDisablesImplicitAnimationForMutation() {
        var mutationRan = false
        var observedDuration: TimeInterval?
        var observedAllowsImplicitAnimation: Bool?

        NSAnimationContext.cmuxPerformWithoutImplicitAnimation {
            mutationRan = true
            observedDuration = NSAnimationContext.current.duration
            observedAllowsImplicitAnimation = NSAnimationContext.current.allowsImplicitAnimation
        }

        #expect(mutationRan)
        #expect(observedDuration == 0)
        #expect(observedAllowsImplicitAnimation == false)
    }

    @Test func hiddenPopoverUpdatesContentSizeDirectly() {
        let popover = NSPopover()
        let contentSize = NSSize(width: 320, height: 240)

        #expect(popover.isShown == false)
        popover.cmuxSetContentSize(contentSize)

        #expect(popover.contentSize == contentSize)
    }
}

#endif
