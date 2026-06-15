import Foundation
import Testing
@testable import CmuxAuthRuntime

/// Multi-account scaffolding spike (see plans/feat-ios-multi-account/DESIGN.md):
/// proves N token stores can coexist in one process when namespaced per account,
/// and that the nil-account derivation preserves today's single-account keychain
/// service byte-for-byte (the migration-safety invariant).
@Suite struct MultiAccountTokenStoreNamespacingTests {
    // MARK: Keychain service derivation

    @Test func nilAccountPreservesLegacyServiceName() {
        #expect(
            KeychainStackTokenStore.serviceName(
                bundleIdentifier: "com.cmuxterm.app",
                accountID: nil
            ) == "com.cmuxterm.app.auth"
        )
        #expect(
            KeychainStackTokenStore.serviceName(
                bundleIdentifier: "com.cmuxterm.app",
                accountID: nil
            ) == KeychainStackTokenStore.serviceName(bundleIdentifier: "com.cmuxterm.app")
        )
    }

    @Test func nilBundlePreservesLegacyFallbackServiceName() {
        #expect(
            KeychainStackTokenStore.serviceName(bundleIdentifier: nil, accountID: nil)
                == "com.cmuxterm.app.auth"
        )
    }

    @Test func accountIDNamespacesServiceName() {
        #expect(
            KeychainStackTokenStore.serviceName(
                bundleIdentifier: "com.cmuxterm.app",
                accountID: "user-work-123"
            ) == "com.cmuxterm.app.auth.account.user-work-123"
        )
    }

    @Test func distinctAccountsDeriveDistinctServices() {
        let work = KeychainStackTokenStore.serviceName(
            bundleIdentifier: "com.cmuxterm.app",
            accountID: "user-work-123"
        )
        let personal = KeychainStackTokenStore.serviceName(
            bundleIdentifier: "com.cmuxterm.app",
            accountID: "user-personal-456"
        )
        let legacy = KeychainStackTokenStore.serviceName(
            bundleIdentifier: "com.cmuxterm.app",
            accountID: nil
        )
        #expect(work != personal)
        #expect(work != legacy)
        #expect(personal != legacy)
    }

    @Test func emptyAccountIDFallsBackToLegacyServiceName() {
        #expect(
            KeychainStackTokenStore.serviceName(
                bundleIdentifier: "com.cmuxterm.app",
                accountID: ""
            ) == "com.cmuxterm.app.auth"
        )
    }

    // MARK: Two stores coexist independently

    @Test func namespacedFileStoresHoldIndependentTokenPairs() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-multi-account-spike-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let workStore = FileStackTokenStore(
            directory: root.appendingPathComponent("accounts/user-work-123")
        )
        let personalStore = FileStackTokenStore(
            directory: root.appendingPathComponent("accounts/user-personal-456")
        )

        await workStore.setTokens(accessToken: "work-access", refreshToken: "work-refresh")
        await personalStore.setTokens(accessToken: "personal-access", refreshToken: "personal-refresh")

        #expect(await workStore.getStoredAccessToken() == "work-access")
        #expect(await workStore.getStoredRefreshToken() == "work-refresh")
        #expect(await personalStore.getStoredAccessToken() == "personal-access")
        #expect(await personalStore.getStoredRefreshToken() == "personal-refresh")
    }

    @Test func signingOutOneAccountLeavesTheOtherIntact() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-multi-account-spike-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let workStore = FileStackTokenStore(
            directory: root.appendingPathComponent("accounts/user-work-123")
        )
        let personalStore = FileStackTokenStore(
            directory: root.appendingPathComponent("accounts/user-personal-456")
        )

        await workStore.setTokens(accessToken: "work-access", refreshToken: "work-refresh")
        await personalStore.setTokens(accessToken: "personal-access", refreshToken: "personal-refresh")

        // Per-account local-first sign-out clears only that account's store.
        await workStore.clearTokens()

        #expect(await workStore.getStoredAccessToken() == nil)
        #expect(await workStore.getStoredRefreshToken() == nil)
        #expect(await personalStore.getStoredAccessToken() == "personal-access")
        #expect(await personalStore.getStoredRefreshToken() == "personal-refresh")
    }
}
