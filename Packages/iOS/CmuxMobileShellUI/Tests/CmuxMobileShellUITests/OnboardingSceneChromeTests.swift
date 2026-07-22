#if os(iOS)
@testable import CmuxMobileShellUI
import Testing

@Suite struct OnboardingSceneChromeTests {
    @Test func productPagesKeepExpectedNavigationChrome() {
        let agents = OnboardingSceneChrome(
            stage: .agents,
            isAuthenticated: true,
            connectionPhase: .searching
        )
        let notifications = OnboardingSceneChrome(
            stage: .notifications,
            isAuthenticated: true,
            connectionPhase: .searching
        )

        #expect(!agents.showsBack)
        #expect(agents.showsSkip)
        #expect(agents.primaryTitle != nil)
        #expect(agents.secondaryTitle == nil)

        #expect(notifications.showsBack)
        #expect(notifications.showsSkip)
        #expect(notifications.primaryTitle != nil)
        #expect(notifications.secondaryTitle == nil)
    }

    @Test func connectionChromeFollowsAuthenticationAndDiscoveryPhase() {
        let signIn = OnboardingSceneChrome(
            stage: .connect,
            isAuthenticated: false,
            connectionPhase: .searching
        )
        let searching = OnboardingSceneChrome(
            stage: .connect,
            isAuthenticated: true,
            connectionPhase: .searching
        )
        let idle = OnboardingSceneChrome(
            stage: .connect,
            isAuthenticated: true,
            connectionPhase: .idle
        )
        let fallback = OnboardingSceneChrome(
            stage: .connect,
            isAuthenticated: true,
            connectionPhase: .fallback
        )
        let ready = OnboardingSceneChrome(
            stage: .connect,
            isAuthenticated: true,
            connectionPhase: .ready
        )

        #expect(signIn.showsBack)
        #expect(!signIn.showsSkip)
        #expect(signIn.primaryTitle == nil)
        #expect(signIn.secondaryTitle == nil)

        #expect(searching.primaryTitle == nil)
        #expect(searching.secondaryTitle == nil)
        #expect(idle.primaryTitle != nil)
        #expect(idle.secondaryTitle == nil)
        #expect(fallback.primaryTitle != nil)
        #expect(fallback.secondaryTitle != nil)
        #expect(ready.primaryTitle != nil)
        #expect(ready.secondaryTitle == nil)
    }
}
#endif
