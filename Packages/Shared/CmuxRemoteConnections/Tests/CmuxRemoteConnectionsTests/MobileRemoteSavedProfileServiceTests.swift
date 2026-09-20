import CryptoKit
import Foundation
import Testing
@testable import CmuxRemoteConnections

@Suite struct MobileRemoteSavedProfileServiceTests {
    @Test func savesMetadataSeparatelyFromTheScopedPasswordAndLoadsIt() async throws {
        let fixture = try ProfileStoreFixture()
        defer { fixture.cleanup() }
        let account = try MobileRemoteAuthenticatedAccount(accountID: "account-1", sessionGeneration: 1)
        let key = SymmetricKey(size: .bits256)
        let profiles = try fixture.store(account: account.accountID, key: key)
        let secrets = SavedProfileTestSecretStore()
        let service = MobileRemoteSavedProfileService(
            profiles: profiles, secrets: secrets, account: account, vaultID: fixture.vaultID
        )
        let saved = try await service.savePasswordProfile(
            fixture.profile(), password: "correct horse battery staple"
        )
        #expect(saved.credentialID != nil)
        #expect((try await profiles.profile(id: saved.id))?.id == saved.id)
        let loaded = try #require(await service.loadPasswordProfile(profileID: saved.id))
        #expect(loaded.profile.id == saved.id)
        #expect(loaded.profile.credentialID == saved.credentialID)
        #expect(loaded.credential == .password("correct horse battery staple"))
        #expect(await secrets.values.count == 1)
    }

    @Test func replacingAProfilePasswordKeepsItsOpaqueCredentialIdentity() async throws {
        let fixture = try ProfileStoreFixture()
        defer { fixture.cleanup() }
        let account = try MobileRemoteAuthenticatedAccount(accountID: "account-1", sessionGeneration: 1)
        let profiles = try fixture.store(account: account.accountID, key: SymmetricKey(size: .bits256))
        let secrets = SavedProfileTestSecretStore()
        let service = MobileRemoteSavedProfileService(
            profiles: profiles, secrets: secrets, account: account, vaultID: fixture.vaultID
        )
        let first = try await service.savePasswordProfile(fixture.profile(), password: "one")
        let second = try await service.savePasswordProfile(first, password: "two")
        #expect(second.credentialID == first.credentialID)
        #expect(try await service.loadPasswordProfile(profileID: first.id)?.credential == .password("two"))
        #expect(await secrets.values.count == 1)
    }

    @Test func removalDeletesTheSecretAfterWritingAnAuthenticatedTombstone() async throws {
        let fixture = try ProfileStoreFixture()
        defer { fixture.cleanup() }
        let account = try MobileRemoteAuthenticatedAccount(accountID: "account-1", sessionGeneration: 1)
        let profiles = try fixture.store(account: account.accountID, key: SymmetricKey(size: .bits256))
        let secrets = SavedProfileTestSecretStore()
        let service = MobileRemoteSavedProfileService(
            profiles: profiles, secrets: secrets, account: account, vaultID: fixture.vaultID
        )
        let saved = try await service.savePasswordProfile(fixture.profile(), password: "one")
        try await service.remove(profileID: saved.id)
        #expect(try await profiles.profile(id: saved.id) == nil)
        #expect(await secrets.values.isEmpty)
    }

    private actor SavedProfileTestSecretStore: MobileRemoteSecretStore {
        struct Record: Sendable { let value: Data; let protection: MobileRemoteSecretProtection }
        var values: [MobileRemoteSecretScope: Record] = [:]

        func insert(_ value: MobileRemoteSecretValue, scope: MobileRemoteSecretScope, protection: MobileRemoteSecretProtection) throws {
            guard values[scope] == nil else { throw MobileRemoteSecretStoreError.itemAlreadyExists }
            values[scope] = Record(value: value.bytes, protection: protection)
        }

        func read(scope: MobileRemoteSecretScope, interaction: MobileRemoteSecretInteraction) throws -> MobileRemoteSecretValue {
            guard let value = values[scope]?.value else { throw MobileRemoteSecretStoreError.itemNotFound }
            return MobileRemoteSecretValue(bytes: value)
        }

        func updateValue(_ value: MobileRemoteSecretValue, scope: MobileRemoteSecretScope, interaction: MobileRemoteSecretInteraction) throws {
            guard let record = values[scope] else { throw MobileRemoteSecretStoreError.itemNotFound }
            values[scope] = Record(value: value.bytes, protection: record.protection)
        }

        func delete(scope: MobileRemoteSecretScope, interaction: MobileRemoteSecretInteraction) throws {
            guard values.removeValue(forKey: scope) != nil else { throw MobileRemoteSecretStoreError.itemNotFound }
        }
    }
}
