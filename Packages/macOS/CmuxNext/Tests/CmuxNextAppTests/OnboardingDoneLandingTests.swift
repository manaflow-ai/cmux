@testable import CmuxNextApp
import Testing

/// D3 (cx-aha.2, spec D9): Skip and Done of the first run, also when
/// Continue Setup reopened it, land on a New Tab page through one path:
/// the fresh launch workspace when there is one, else a new workspace. A
/// window that shows a workspace or another page stays as it is, and a
/// single-step window (Import and Sync) never moves the window.
@MainActor @Suite struct OnboardingDoneLandingTests {
    @Test func overHomeTheFreshWorkspaceIsSelected() {
        #expect(OnboardingLanding.decide(firstRun: true, hasOpenWindow: true, shown: .home, fresh: "w1") == .select(workspaceID: "w1"))
    }

    @Test func overHomeWithoutAFreshWorkspaceANewOneOpens() {
        #expect(OnboardingLanding.decide(firstRun: true, hasOpenWindow: true, shown: .home, fresh: nil) == .newWorkspace)
    }

    /// No main window (closed during onboarding): the fresh workspace
    /// opens one, else a new workspace does.
    @Test func withNoWindowOneOpensOnTheNewTabPage() {
        #expect(OnboardingLanding.decide(firstRun: true, hasOpenWindow: false, shown: nil, fresh: "w1") == .select(workspaceID: "w1"))
        #expect(OnboardingLanding.decide(firstRun: true, hasOpenWindow: false, shown: nil, fresh: nil) == .newWorkspace)
    }

    @Test func overAWorkspaceOrAnotherPageTheWindowStays() {
        #expect(OnboardingLanding.decide(firstRun: true, hasOpenWindow: true, shown: nil, fresh: "w1") == .stay)
        #expect(OnboardingLanding.decide(firstRun: true, hasOpenWindow: true, shown: .page(.appStore), fresh: "w1") == .stay)
    }

    @Test func aSingleStepWindowNeverMovesTheWindow() {
        #expect(OnboardingLanding.decide(firstRun: false, hasOpenWindow: true, shown: .home, fresh: "w1") == .stay)
        #expect(OnboardingLanding.decide(firstRun: false, hasOpenWindow: false, shown: nil, fresh: nil) == .stay)
    }
}
