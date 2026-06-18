#if os(iOS)
import Testing
@testable import CmuxMobileShellUI

/// Behavior tests for the notification opt-in surfaces: the workspaces-list
/// banner visibility rule and the onboarding flow's final "enable notifications"
/// page.
@Suite struct NotificationOnboardingTests {
    // MARK: Banner visibility

    @Test func bannerShowsOnlyWhenOffAndNotDismissed() {
        #expect(NotificationBannerPolicy.shouldShow(isEnabled: false, dismissedForever: false))
        #expect(!NotificationBannerPolicy.shouldShow(isEnabled: true, dismissedForever: false))
        #expect(!NotificationBannerPolicy.shouldShow(isEnabled: false, dismissedForever: true))
        #expect(!NotificationBannerPolicy.shouldShow(isEnabled: true, dismissedForever: true))
    }

    // MARK: Onboarding page plan

    @Test func notificationsIsTheFinalPageAndCarriesTheEnableKind() {
        let pages = OnboardingPage.allPages
        #expect(pages.last?.kind == .enableNotifications)
        // Exactly one action page; the rest stay plain info pages.
        #expect(pages.filter { $0.kind == .enableNotifications }.count == 1)
        #expect(pages.dropLast().allSatisfy { $0.kind == .info })
    }

    @Test func notificationsPageHasContent() {
        guard let page = OnboardingPage.allPages.last else {
            Issue.record("expected a final onboarding page")
            return
        }
        #expect(!page.title.isEmpty)
        #expect(!page.body.isEmpty)
        #expect(page.systemImage == "bell.badge")
    }
}
#endif
