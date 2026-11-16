import CmuxAuthRuntime
@testable import CmuxMobileAuth
import Testing

/// A DEBUG launch with `CMUX_MOBILE_STACK_REFRESH_TOKEN` (a fleet step's own session, delivered from its
/// submitter's Mac) starts signed in with no password: the app's token store adopts it while empty.
@Suite struct LaunchTokenStoreTests {
    private static let variable = "CMUX_MOBILE_STACK_REFRESH_TOKEN"

    @Test func anEmptyAppAdoptsTheLaunchSession() async {
        let primary = MemoryStackTokenStore()
        let store = CmuxMobileAuthModel.launchTokenStore(primary: primary, environment: [Self.variable: "step-session"])
        #expect(await store.getStoredRefreshToken() == "step-session")
        #expect(await store.getStoredAccessToken() == nil)
        // Kept in the app's own store: the relaunch with no variable restores it.
        #expect(await primary.getStoredRefreshToken() == "step-session")
        // The app's own session from now on: its sign-out revokes it on the server.
        #expect(await (store as? ImportingTokenStore)?.isShared(refreshToken: "step-session") == false)
    }

    @Test func theAppsOwnSessionWins() async {
        let primary = MemoryStackTokenStore()
        await primary.setTokens(accessToken: "own-access", refreshToken: "own-session")
        let store = CmuxMobileAuthModel.launchTokenStore(primary: primary, environment: [Self.variable: "step-session"])
        #expect(await store.getStoredRefreshToken() == "own-session")
        #expect(await primary.getStoredRefreshToken() == "own-session")
    }

    @Test func noOrAnEmptyVariableLeavesTheAppsStore() async {
        for environment in [[:], [Self.variable: ""]] {
            let primary = MemoryStackTokenStore()
            let store = CmuxMobileAuthModel.launchTokenStore(primary: primary, environment: environment)
            #expect(store as AnyObject === primary as AnyObject)
            #expect(await store.getStoredRefreshToken() == nil)
        }
    }
}
