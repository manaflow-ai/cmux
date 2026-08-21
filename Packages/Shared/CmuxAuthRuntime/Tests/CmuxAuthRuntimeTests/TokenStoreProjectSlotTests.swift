import Foundation
#if canImport(Security)
import Security
#endif
import Testing
@testable import CmuxAuthRuntime

/// Per-project token slots (backend-environment switch parking): naming,
/// coexistence of two projects' slots, un-suffixed legacy adoption, and
/// own-slot-only clears.
@Suite struct TokenStoreProjectSlotTests {
    // MARK: - Naming statics (pure)

    @Test func keychainAccountNamingSuffixesProjectID() {
        #expect(
            KeychainStackTokenStore.account(base: "cmux-auth-access-token", projectID: "pid-1")
                == "cmux-auth-access-token.pid-1"
        )
        #expect(
            KeychainStackTokenStore.account(base: "cmux-auth-access-token", projectID: nil)
                == "cmux-auth-access-token"
        )
        #expect(
            KeychainStackTokenStore.account(base: "cmux-auth-refresh-token", projectID: "")
                == "cmux-auth-refresh-token"
        )
    }

    @Test func fileNameKeysPerProjectAndSanitizes() {
        #expect(FileStackTokenStore.fileName(projectID: nil) == "credentials.json")
        #expect(FileStackTokenStore.fileName(projectID: "") == "credentials.json")
        #expect(
            FileStackTokenStore.fileName(projectID: "454ecd03-abcd")
                == "credentials.454ecd03-abcd.json"
        )
        // Path separators and dots can never traverse or alias the legacy name.
        #expect(
            FileStackTokenStore.fileName(projectID: "../evil")
                == "credentials.---evil.json"
        )
        #expect(
            FileStackTokenStore.fileName(projectID: "a/b.c")
                == "credentials.a-b-c.json"
        )
    }

    // MARK: - File store slots

    @Test func fileStoresForDifferentProjectsCoexist() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let production = FileStackTokenStore(directory: directory, projectID: "prod-project")
        let staging = FileStackTokenStore(directory: directory, projectID: "dev-project")
        await production.setTokens(accessToken: "prod-access", refreshToken: "prod-refresh")
        await staging.setTokens(accessToken: "stg-access", refreshToken: "stg-refresh")

        #expect(await production.getStoredAccessToken() == "prod-access")
        #expect(await staging.getStoredAccessToken() == "stg-access")

        // Fresh instances prove the slots persisted independently on disk.
        let production2 = FileStackTokenStore(directory: directory, projectID: "prod-project")
        let staging2 = FileStackTokenStore(directory: directory, projectID: "dev-project")
        #expect(await production2.getStoredRefreshToken() == "prod-refresh")
        #expect(await staging2.getStoredRefreshToken() == "stg-refresh")
    }

    @Test func fileStoreAdoptsUnsuffixedLegacyFileAndDeletesIt() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        // Seed the pre-per-project single slot.
        let legacy = FileStackTokenStore(directory: directory)
        await legacy.setTokens(accessToken: "legacy-access", refreshToken: "legacy-refresh")
        let legacyURL = directory.appendingPathComponent("credentials.json", isDirectory: false)
        #expect(FileManager.default.fileExists(atPath: legacyURL.path))

        let keyed = FileStackTokenStore(directory: directory, projectID: "prod-project")
        #expect(await keyed.getStoredAccessToken() == "legacy-access")
        #expect(await keyed.getStoredRefreshToken() == "legacy-refresh")

        // Adopted into the per-project file; un-suffixed slot deleted.
        #expect(!FileManager.default.fileExists(atPath: legacyURL.path))
        let keyedURL = directory.appendingPathComponent(
            "credentials.prod-project.json",
            isDirectory: false
        )
        #expect(FileManager.default.fileExists(atPath: keyedURL.path))

        // A fresh keyed instance reads the adopted slot without the legacy file.
        let keyed2 = FileStackTokenStore(directory: directory, projectID: "prod-project")
        #expect(await keyed2.getStoredAccessToken() == "legacy-access")
    }

    @Test func fileStorePerProjectSlotWinsOverLegacyFile() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let keyed = FileStackTokenStore(directory: directory, projectID: "prod-project")
        await keyed.setTokens(accessToken: "own-access", refreshToken: "own-refresh")
        let legacy = FileStackTokenStore(directory: directory)
        await legacy.setTokens(accessToken: "legacy-access", refreshToken: "legacy-refresh")

        let keyed2 = FileStackTokenStore(directory: directory, projectID: "prod-project")
        #expect(await keyed2.getStoredAccessToken() == "own-access")
        // The legacy file is not adopted (own slot existed), so it survives.
        let legacyURL = directory.appendingPathComponent("credentials.json", isDirectory: false)
        #expect(FileManager.default.fileExists(atPath: legacyURL.path))
    }

    @Test func fileStoreClearTokensClearsOwnSlotAndLegacyOnly() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let production = FileStackTokenStore(directory: directory, projectID: "prod-project")
        let staging = FileStackTokenStore(directory: directory, projectID: "dev-project")
        let legacy = FileStackTokenStore(directory: directory)
        await production.setTokens(accessToken: "prod-access", refreshToken: "prod-refresh")
        await staging.setTokens(accessToken: "stg-access", refreshToken: "stg-refresh")
        await legacy.setTokens(accessToken: "legacy-access", refreshToken: "legacy-refresh")

        await production.clearTokens()

        #expect(await production.getStoredAccessToken() == nil)
        #expect(await production.getStoredRefreshToken() == nil)
        // The legacy adoption source is cleared with the own slot...
        let legacyURL = directory.appendingPathComponent("credentials.json", isDirectory: false)
        #expect(!FileManager.default.fileExists(atPath: legacyURL.path))
        // ...but the OTHER project's parked slot survives.
        let staging2 = FileStackTokenStore(directory: directory, projectID: "dev-project")
        #expect(await staging2.getStoredAccessToken() == "stg-access")
        #expect(await staging2.getStoredRefreshToken() == "stg-refresh")
    }

    @Test func nilProjectIDFileStoreKeepsHistoricalBehavior() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = FileStackTokenStore(directory: directory)
        await store.setTokens(accessToken: "access-1", refreshToken: "refresh-1")
        let legacyURL = directory.appendingPathComponent("credentials.json", isDirectory: false)
        #expect(FileManager.default.fileExists(atPath: legacyURL.path))

        await store.clearTokens()
        #expect(await store.getStoredAccessToken() == nil)
        let fresh = FileStackTokenStore(directory: directory)
        #expect(await fresh.getStoredRefreshToken() == nil)
    }

    // MARK: - Keychain slots (real Keychain, unique service names)

    #if canImport(Security)
    @Test func keychainStoresForDifferentProjectsCoexistAndClearOwnSlotOnly() async throws {
        let service = "com.cmux.tests.TokenStoreProjectSlotTests.\(UUID().uuidString)"
        defer { deleteAllItems(service: service) }

        let production = KeychainStackTokenStore(service: service, projectID: "prod-project")
        let staging = KeychainStackTokenStore(service: service, projectID: "dev-project")
        guard await production.trySetTokens(
            accessToken: "prod-access",
            refreshToken: "prod-refresh"
        ) else {
            // Ad-hoc test hosts without a keychain entitlement cannot exercise
            // the data-protection keychain; the file-store suite carries the
            // slot semantics there.
            return
        }
        #expect(await staging.trySetTokens(accessToken: "stg-access", refreshToken: "stg-refresh"))

        // Fresh instances (no warm cache) prove the slots persisted independently.
        let production2 = KeychainStackTokenStore(service: service, projectID: "prod-project")
        let staging2 = KeychainStackTokenStore(service: service, projectID: "dev-project")
        #expect(await production2.getStoredAccessToken() == "prod-access")
        #expect(await staging2.getStoredAccessToken() == "stg-access")

        await production2.clearTokens()
        let production3 = KeychainStackTokenStore(service: service, projectID: "prod-project")
        let staging3 = KeychainStackTokenStore(service: service, projectID: "dev-project")
        #expect(await production3.getStoredAccessToken() == nil)
        #expect(await staging3.getStoredAccessToken() == "stg-access")
        #expect(await staging3.getStoredRefreshToken() == "stg-refresh")
    }

    @Test func keychainStoreAdoptsUnsuffixedLegacySlotAndDeletesIt() async throws {
        let service = "com.cmux.tests.TokenStoreProjectSlotTests.\(UUID().uuidString)"
        defer { deleteAllItems(service: service) }

        // Seed the pre-per-project single slot (un-suffixed account names).
        let legacy = KeychainStackTokenStore(service: service)
        guard await legacy.trySetTokens(
            accessToken: "legacy-access",
            refreshToken: "legacy-refresh"
        ) else { return }

        let keyed = KeychainStackTokenStore(service: service, projectID: "prod-project")
        #expect(await keyed.getStoredAccessToken() == "legacy-access")
        #expect(await keyed.getStoredRefreshToken() == "legacy-refresh")

        // Adopted into the suffixed slot; the un-suffixed items are gone, so a
        // fresh un-suffixed store reads nothing.
        let legacy2 = KeychainStackTokenStore(service: service)
        #expect(await legacy2.getStoredAccessToken() == nil)
        #expect(await legacy2.getStoredRefreshToken() == nil)
        let keyed2 = KeychainStackTokenStore(service: service, projectID: "prod-project")
        #expect(await keyed2.getStoredAccessToken() == "legacy-access")
    }

    private func deleteAllItems(service: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecUseDataProtectionKeychain as String: true,
        ]
        _ = SecItemDelete(query as CFDictionary)
    }
    #endif

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CmuxAuthRuntimeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return directory
    }
}
