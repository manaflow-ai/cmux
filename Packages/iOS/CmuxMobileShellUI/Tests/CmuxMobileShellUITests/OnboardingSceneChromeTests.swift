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
        let reserved = OnboardingSceneChrome(
            stage: .reserved,
            isAuthenticated: true,
            connectionPhase: .searching
        )

        #expect(!agents.showsBack)
        #expect(agents.showsSkip)
        #expect(agents.primaryTitle != nil)
        #expect(agents.secondaryTitle == nil)

        #expect(reserved.showsBack)
        #expect(reserved.showsSkip)
        #expect(reserved.primaryTitle != nil)
        #expect(reserved.secondaryTitle == nil)
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
        #expect(fallback.primaryTitle != nil)
        #expect(fallback.secondaryTitle != nil)
        #expect(ready.primaryTitle != nil)
        #expect(ready.secondaryTitle == nil)
    }
}
#endif
