#if canImport(AppKit)

import Testing
@testable import CmuxAppKitSupportUI

@Suite struct ArrowlessPopoverRootViewUpdatePolicyTests {
    @Test func hiddenClosedPopoverDoesNotNeedHostedRootRefresh() {
        #expect(ArrowlessPopoverRootViewUpdatePolicy.shouldUpdateRootView(
            isPresented: false,
            popoverIsShown: false
        ) == false)
    }

    @Test func presentedOrVisiblePopoverKeepsHostedRootFresh() {
        #expect(ArrowlessPopoverRootViewUpdatePolicy.shouldUpdateRootView(
            isPresented: true,
            popoverIsShown: false
        ))
        #expect(ArrowlessPopoverRootViewUpdatePolicy.shouldUpdateRootView(
            isPresented: false,
            popoverIsShown: true
        ))
        #expect(ArrowlessPopoverRootViewUpdatePolicy.shouldUpdateRootView(
            isPresented: true,
            popoverIsShown: true
        ))
    }
}

#endif
