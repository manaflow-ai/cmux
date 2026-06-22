#if canImport(AppKit)

import Testing
@testable import CmuxAppKitSupportUI

@Suite struct ArrowlessPopoverRootViewUpdatePolicyTests {
    @Test func hiddenClosedPopoverDoesNotNeedHostedRootRefresh() {
        let policy = ArrowlessPopoverRootViewUpdatePolicy()

        #expect(policy.shouldUpdateRootView(isPresented: false, popoverIsShown: false) == false)
    }

    @Test func presentedOrVisiblePopoverKeepsHostedRootFresh() {
        let policy = ArrowlessPopoverRootViewUpdatePolicy()

        #expect(policy.shouldUpdateRootView(isPresented: true, popoverIsShown: false))
        #expect(policy.shouldUpdateRootView(isPresented: false, popoverIsShown: true))
    }
}

#endif
