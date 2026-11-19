import CmuxAuthRuntime
@testable import CmuxNextCloud
import Foundation
import Testing

/// ``SharedSessionTokenStore``: Team-signed production builds share one sign-in item. The build's own session
/// wins; signed out, it imports the item read-only in memory; it shares only its own session. Memory stores
/// stand in for this build's Keychain store and the shared item.
@Suite struct SharedSessionTokenStoreTests {
    private func stores(own: (String, String)? = nil, shared: (String, String)? = nil) async
        -> (store: SharedSessionTokenStore, own: MemoryStackTokenStore, shared: MemoryStackTokenStore) {
        let ownStore = MemoryStackTokenStore()
        let sharedStore = MemoryStackTokenStore()
        if let own { await ownStore.setTokens(accessToken: own.0, refreshToken: own.1) }
        if let shared { await sharedStore.setTokens(accessToken: shared.0, refreshToken: shared.1) }
        return (SharedSessionTokenStore(own: ownStore, shared: sharedStore), ownStore, sharedStore)
    }

    @Test func anOwnSessionWinsOverTheSharedItem() async {
        let (store, _, shared) = await stores(own: ("a1", "r1"), shared: ("a2", "r2"))
        #expect(await store.getStoredRefreshToken() == "r1")
        #expect(await store.getStoredAccessToken() == "a1")
        #expect(await store.isShared(refreshToken: "r1") == false)
        #expect(await shared.getStoredRefreshToken() == "r2")
    }

    @Test func signedOutItImportsTheItemReadOnlyInMemory() async {
        let (store, own, shared) = await stores(shared: ("a2", "r2"))
        #expect(await store.getStoredRefreshToken() == "r2")
        #expect(await store.getStoredAccessToken() == "a2")
        // The writer's session: a sign-out here keeps it on the server.
        #expect(await store.isShared(refreshToken: "r2"))
        #expect(await own.getStoredRefreshToken() == nil)
        // A refresh stays in memory and is still the writer's session.
        await store.compareAndSet(compareRefreshToken: "r2", newRefreshToken: "r3", newAccessToken: "a3")
        #expect(await store.getStoredRefreshToken() == "r3")
        #expect(await store.isShared(refreshToken: "r3"))
        #expect(await own.getStoredRefreshToken() == nil)
        #expect(await shared.getStoredRefreshToken() == "r2")
        // A sign-out forgets it and leaves the item.
        await store.clearTokens()
        #expect(await store.getStoredRefreshToken() == nil)
        #expect(await shared.getStoredRefreshToken() == "r2")
        #expect(await shared.getStoredAccessToken() == "a2")
    }

    @Test func aRejectedImportSignsOutAndLeavesTheItem() async {
        let (store, _, shared) = await stores(shared: ("a2", "r2"))
        #expect(await store.getStoredRefreshToken() == "r2")
        await store.compareAndSet(compareRefreshToken: "r2", newRefreshToken: nil, newAccessToken: nil)
        #expect(await store.getStoredRefreshToken() == nil)
        #expect(await shared.getStoredRefreshToken() == "r2")
    }

    @Test func aSignInIsStoredAsItsOwnAndShared() async {
        let (store, own, shared) = await stores()
        #expect(await store.getStoredRefreshToken() == nil)
        await store.setTokens(accessToken: "a1", refreshToken: "r1")
        #expect(await own.getStoredRefreshToken() == "r1")
        #expect(await shared.getStoredRefreshToken() == "r1")
        #expect(await store.isShared(refreshToken: "r1") == false)
        // A refresh is shared too.
        await store.compareAndSet(compareRefreshToken: "r1", newRefreshToken: "r1b", newAccessToken: "a1b")
        #expect(await shared.getStoredRefreshToken() == "r1b")
        #expect(await shared.getStoredAccessToken() == "a1b")
        // Its sign-out removes the item it wrote.
        await store.clearTokens()
        #expect(await own.getStoredRefreshToken() == nil)
        #expect(await shared.getStoredRefreshToken() == nil)
    }

    @Test func aSignOutLeavesAnotherBuildsItem() async {
        let (store, _, shared) = await stores()
        await store.setTokens(accessToken: "a1", refreshToken: "r1")
        // Another Team-signed build signed in since and wrote its own session.
        await shared.setTokens(accessToken: "a9", refreshToken: "r9")
        await store.clearTokens()
        #expect(await shared.getStoredRefreshToken() == "r9")
    }

    @Test func aSignInAfterAnImportReplacesItWithItsOwn() async {
        let (store, own, shared) = await stores(shared: ("a2", "r2"))
        #expect(await store.getStoredRefreshToken() == "r2")
        await store.setTokens(accessToken: "a5", refreshToken: "r5")
        #expect(await store.getStoredRefreshToken() == "r5")
        #expect(await own.getStoredRefreshToken() == "r5")
        #expect(await shared.getStoredRefreshToken() == "r5")
        #expect(await store.isShared(refreshToken: "r5") == false)
    }

    @Test func aSignInBeforeTheFirstReadNeverImports() async {
        let (store, own, _) = await stores(shared: ("a2", "r2"))
        await store.setTokens(accessToken: "a1", refreshToken: "r1")
        #expect(await store.getStoredRefreshToken() == "r1")
        #expect(await own.getStoredRefreshToken() == "r1")
        #expect(await store.isShared(refreshToken: "r2") == false)
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
            #expect(CloudAuth.tokenStore(configuration: configuration, nightlySession: nil) is SharedSessionTokenStore)
            // A memory-only launch never opens the Keychain.
            #expect(CloudAuth.tokenStore(configuration: configuration, nightlySession: nil, memoryOnly: true) is MemoryStackTokenStore)
        }
    }

    @Test func otherBuildsDoNotShare() {
        let debug = CloudConfiguration.resolve(bundleID: "com.cmuxterm.app.debug.tag", bundled: [:], process: [:], isDebugBuild: true)
        #expect(debug.sharedSession == nil)
        #expect(!(CloudAuth.tokenStore(configuration: debug, nightlySession: nil) is SharedSessionTokenStore))
        // Signed NEXT DEV embeds no provisioning profile: it keeps the NIGHTLY handoff only.
        let nextDev = CloudConfiguration.resolve(bundleID: "com.cmuxterm.app.debug.next", bundled: [:], process: [:], isDebugBuild: false)
        #expect(nextDev.sharedSession == nil)
        #expect(nextDev.adoptsNightlySession)
        #expect(CloudAuth.tokenStore(configuration: nextDev, nightlySession: nil) is ImportingTokenStore)
    }
}
