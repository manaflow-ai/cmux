import CMUXAuthCore
import CmuxAuthRuntime
@testable import CmuxNextCloud
import Foundation
import Testing

/// Regression (2026-11-18): no dev build takes cmux NIGHTLY's signed-in session. The production cloud-api ignores
/// `X-Cmux-Build-Space`, so a dev build on NIGHTLY's session would read and write NIGHTLY's real data. A tagged dev
/// build with no dev account configured keeps its own store and starts signed out, even while NIGHTLY is signed in:
/// it signs in itself, once per build, in the browser.
///
/// The tests-first commit ran this with a signed-in NIGHTLY handing its session over (`auth.session.handoff`), and
/// it failed: that build adopted NIGHTLY's session into a memory store. That source no longer exists, so a dev
/// build's launch store is its own: an adoption brought back in any shape (a memory store, or an importing store
/// fed from NIGHTLY) fails here.
@MainActor @Suite struct CloudAuthNeverNightlySessionTests {
    /// A tagged dev build (`dev:next`) on the production account, NIGHTLY's.
    static func taggedDevBuildOnProduction() -> CloudConfiguration {
        var configuration = CloudConfiguration.unavailable
        configuration.isProductionAuth = true
        configuration.buildSpace = CMUXBuildSpaceState(devBuild: true, devTag: "next")
        return configuration
    }

    @Test func aTaggedDevBuildWithNoDevAccountStaysSignedOutWhileNightlyIsSignedIn() async throws {
        let configuration = Self.taggedDevBuildOnProduction()
        // No dev account: the launch signs nothing in, so the store is the one CloudAuth.init builds for it.
        let store = CloudAuth.tokenStore(configuration: configuration)
        // The build's own Keychain store with its file fallback, never a memory store filled from NIGHTLY.
        #expect(store is FallbackTokenStore)
        #expect(!(store is ImportingTokenStore))
        #expect(!(store is MemoryStackTokenStore))
    }
}

/// ``SharedSessionTokenStore``'s Keychain I/O: it performs Rust's effects (cmux-cloud-config
/// `shared_session_store`, where the rules and their cases live) on its stores. Memory stores stand in for this
/// build's Keychain store and the shared item.
@Suite struct SharedSessionTokenStoreIOTests {
    @Test func anImportStaysInMemoryAndASignInIsShared() async {
        let own = MemoryStackTokenStore(), shared = MemoryStackTokenStore()
        await shared.setTokens(accessToken: "a2", refreshToken: "r2")
        let store = SharedSessionTokenStore(own: own, shared: shared)
        #expect(await store.getStoredRefreshToken() == "r2")
        #expect(await store.isShared(refreshToken: "r2"))
        await store.compareAndSet(compareRefreshToken: "r2", newRefreshToken: "r3", newAccessToken: "a3")
        #expect(await store.getStoredAccessToken() == "a3")
        #expect(await own.getStoredRefreshToken() == nil)
        #expect(await shared.getStoredRefreshToken() == "r2")
        await store.setTokens(accessToken: "a5", refreshToken: "r5")
        #expect(await own.getStoredRefreshToken() == "r5")
        #expect(await shared.getStoredRefreshToken() == "r5")
        #expect(await store.clearTokensIfCurrent(accessToken: nil, refreshToken: "r5"))
        #expect(await own.getStoredRefreshToken() == nil)
        #expect(await shared.getStoredRefreshToken() == nil)
    }
}

/// Which builds share the item is Rust's (cmux-cloud-config `shared_session`); this checks the app gets the answer
/// and composes the store from it.
@MainActor @Suite struct CloudConfigurationSharedSessionTests {
    @Test func teamSignedProductionChannelsShareOneItem() {
        for bundleID in ["com.cmuxterm.app", "com.cmuxterm.app.nightly", "com.cmuxterm.app.rc"] {
            let configuration = CloudConfiguration.resolve(bundleID: bundleID, bundled: [:], process: [:], isDebugBuild: false)
            #expect(configuration.sharedSession == .init(keychainService: "com.cmuxterm.app.shared.auth.fixture",
                                                         accessGroup: "7WLXT3NR37.com.cmuxterm.app.shared"))
            #expect(CloudAuth.tokenStore(configuration: configuration) is SharedSessionTokenStore)
            // A memory-only launch never opens the Keychain.
            #expect(CloudAuth.tokenStore(configuration: configuration, memoryOnly: true) is MemoryStackTokenStore)
        }
    }

    @Test func otherBuildsDoNotShare() {
        let debug = CloudConfiguration.resolve(bundleID: "com.cmuxterm.app.debug.tag", bundled: [:], process: [:], isDebugBuild: true)
        #expect(debug.sharedSession == nil)
        #expect(!(CloudAuth.tokenStore(configuration: debug) is SharedSessionTokenStore))
        // Signed NEXT DEV embeds no provisioning profile: it shares nothing, and takes no other build's session (cmux#43648).
        let nextDev = CloudConfiguration.resolve(bundleID: "com.cmuxterm.app.debug.next", bundled: [:], process: [:], isDebugBuild: false)
        #expect(nextDev.sharedSession == nil)
        #expect(!(CloudAuth.tokenStore(configuration: nextDev) is SharedSessionTokenStore))
    }
}
