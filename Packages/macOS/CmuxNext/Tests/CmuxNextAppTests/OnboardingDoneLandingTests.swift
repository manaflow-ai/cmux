@testable import CmuxNextApp
import Testing

/// Leo, 2026-10-06: Done at the end of onboarding lands on the New Tab
/// page, not Home. Skip, and onboarding reopened over a workspace or
/// another page, leave the window as it is.
@MainActor @Suite struct OnboardingDoneLandingTests {
    @Test func doneOverHomeOpensTheNewTabPage() {
        #expect(OnboardingService.opensNewTab(completed: true, shown: .home))
    }

    @Test func skipStaysOnHome() {
        #expect(!OnboardingService.opensNewTab(completed: false, shown: .home))
    }

    @Test func doneOverAWorkspaceOrAnotherPageStaysPut() {
        #expect(!OnboardingService.opensNewTab(completed: true, shown: nil))
        #expect(!OnboardingService.opensNewTab(completed: true, shown: .page(.appStore)))
    }
}
