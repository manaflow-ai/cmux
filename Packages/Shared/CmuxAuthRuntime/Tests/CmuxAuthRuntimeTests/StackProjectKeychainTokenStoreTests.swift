import Foundation
import Testing
@testable import CmuxAuthRuntime

#if canImport(Security)
@Suite struct StackProjectKeychainTokenStoreTests {
    @Test func compareAndSetNilPairClearsMatchingRefreshToken() async {
        let store = StackProjectKeychainTokenStore(projectId: UUID().uuidString)
        await store.clearTokens()

        await store.setTokens(accessToken: "access-1", refreshToken: "refresh-1")
        await store.compareAndSet(
            compareRefreshToken: "other-refresh",
            newRefreshToken: nil,
            newAccessToken: nil
        )

        #expect(await store.getStoredAccessToken() == "access-1")
        #expect(await store.getStoredRefreshToken() == "refresh-1")

        await store.compareAndSet(
            compareRefreshToken: "refresh-1",
            newRefreshToken: nil,
            newAccessToken: nil
        )

        #expect(await store.getStoredAccessToken() == nil)
        #expect(await store.getStoredRefreshToken() == nil)
        await store.clearTokens()
    }

    @Test func clearTokensDropsCachedValues() async {
        let store = StackProjectKeychainTokenStore(projectId: UUID().uuidString)
        await store.clearTokens()

        await store.setTokens(accessToken: "access-1", refreshToken: "refresh-1")
        #expect(await store.getStoredAccessToken() == "access-1")
        #expect(await store.getStoredRefreshToken() == "refresh-1")

        await store.clearTokens()

        #expect(await store.getStoredAccessToken() == nil)
        #expect(await store.getStoredRefreshToken() == nil)
    }
}
#endif
