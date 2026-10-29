import CryptoKit
import Foundation
import Testing

@testable import CmuxIrxTransport

struct V2KeychainStoreTests {
    private let service = "test.service"
    private let account = "test.account"

    @Test
    func migratesLegacyValueOnlyAfterPrimaryVerification() throws {
        let access = V2KeychainTestAccess(supportsLegacyFileKeychain: true)
        let legacy = Data(repeating: 7, count: 32)
        access.seed(legacy, service: service, account: account, dataProtection: false)
        let store = V2KeychainStore(
            service: service,
            access: access
        )

        let value = try store.loadOrCreate(
            account: account,
            candidate: Data(repeating: 9, count: 32),
            validate: { data in
                guard data.count == 32 else { throw V2ControlFailure.persistenceFailed }
            }
        )

        #expect(value == legacy)
        #expect(access.value(service: service, account: account, dataProtection: true) == legacy)
        #expect(access.value(service: service, account: account, dataProtection: false) == nil)
        #expect(access.reads.map(\.dataProtection) == [true, false, true])
        #expect(access.deletes == [V2KeychainTestKey(
            service: service, account: account, accessGroup: nil, dataProtection: false
        )])
    }

    @Test
    func keepsLegacyValueWhenPrimaryWriteFails() throws {
        let access = V2KeychainTestAccess(supportsLegacyFileKeychain: true)
        let legacy = Data(repeating: 3, count: 32)
        access.seed(legacy, service: service, account: account, dataProtection: false)
        access.addError = V2KeychainAccessError.status(-50)
        let store = V2KeychainStore(
            service: service,
            access: access
        )

        #expect(throws: V2ControlFailure.persistenceFailed) {
            try store.loadOrCreate(
                account: account,
                candidate: Data(repeating: 8, count: 32),
                validate: { data in
                    guard data.count == 32 else { throw V2ControlFailure.persistenceFailed }
                }
            )
        }
        #expect(access.value(service: service, account: account, dataProtection: false) == legacy)
        #expect(access.deletes.isEmpty)
    }

    @Test
    func rejectsMalformedLegacyBytesWithoutCopyingOrDeletingThem() throws {
        let access = V2KeychainTestAccess(supportsLegacyFileKeychain: true)
        access.seed(Data([1, 2, 3]), service: service, account: account, dataProtection: false)
        let store = V2KeychainStore(
            service: service,
            access: access
        )

        #expect(throws: V2ControlFailure.persistenceFailed) {
            try store.loadOrCreate(
                account: account,
                candidate: Data(repeating: 8, count: 32),
                validate: { data in
                    guard data.count == 32 else { throw V2ControlFailure.persistenceFailed }
                }
            )
        }
        #expect(access.adds.isEmpty)
        #expect(access.deletes.isEmpty)
    }

    @Test
    func rejectsMalformedPrimaryBytesWithoutFallingBackToLegacy() throws {
        let access = V2KeychainTestAccess(supportsLegacyFileKeychain: true)
        let legacy = Data(repeating: 7, count: 32)
        access.seed(Data([1, 2, 3]), service: service, account: account, dataProtection: true)
        access.seed(legacy, service: service, account: account, dataProtection: false)
        let store = V2KeychainStore(service: service, access: access)

        #expect(throws: V2ControlFailure.persistenceFailed) {
            try store.loadOrCreate(
                account: account,
                candidate: Data(repeating: 8, count: 32),
                validate: { data in
                    guard data.count == 32 else { throw V2ControlFailure.persistenceFailed }
                }
            )
        }
        #expect(access.adds.isEmpty)
        #expect(access.deletes.isEmpty)
        #expect(access.value(service: service, account: account, dataProtection: false) == legacy)
    }

    @Test
    func failsClosedWhenPrimaryKeychainIsUnavailable() throws {
        let access = V2KeychainTestAccess(supportsLegacyFileKeychain: true)
        access.readError = V2KeychainAccessError.status(-25308)
        let store = V2KeychainStore(
            service: service,
            access: access
        )

        #expect(throws: V2ControlFailure.persistenceFailed) {
            try store.loadOrCreate(
                account: account,
                candidate: Data(repeating: 8, count: 32),
                validate: { _ in }
            )
        }
        #expect(access.reads.isEmpty)
    }

    @Test
    func duplicateCreationReturnsPersistedWinner() throws {
        let access = V2KeychainTestAccess()
        let winner = Data(repeating: 4, count: 32)
        access.addError = V2KeychainAccessError.duplicate
        access.duplicateWinner = winner
        let store = V2KeychainStore(service: service, access: access)

        let value = try store.loadOrCreate(
            account: account,
            candidate: Data(repeating: 8, count: 32),
            validate: { data in
                guard data.count == 32 else { throw V2ControlFailure.persistenceFailed }
            }
        )

        #expect(value == winner)
        #expect(access.adds.count == 1)
        #expect(access.reads.map(\.dataProtection) == [true, true])
    }

    @Test
    func doesNotProbeOrDeleteLegacyDomainWhenMigrationIsDisabled() throws {
        let access = V2KeychainTestAccess()
        let legacy = Data(repeating: 3, count: 32)
        access.seed(legacy, service: service, account: account, dataProtection: false)
        let candidate = Data(repeating: 8, count: 32)
        let store = V2KeychainStore(service: service, access: access)

        let value = try store.loadOrCreate(
            account: account,
            candidate: candidate,
            validate: { data in
                guard data.count == 32 else { throw V2ControlFailure.persistenceFailed }
            }
        )

        #expect(value == candidate)
        #expect(access.reads.map(\.dataProtection) == [true, true])
        #expect(access.deletes.isEmpty)
        #expect(access.value(service: service, account: account, dataProtection: false) == legacy)
    }

    @Test
    func skipsLegacyProbeAfterMigrationMarker() throws {
        let access = V2KeychainTestAccess(supportsLegacyFileKeychain: true)
        let store = V2KeychainStore(service: service, access: access)
        let candidate = Data(repeating: 8, count: 32)
        let validate: @Sendable (Data) throws -> Void = { data in
            guard data.count == 32 else { throw V2ControlFailure.persistenceFailed }
        }

        _ = try store.loadOrCreate(account: account, candidate: candidate, validate: validate)
        access.legacyReadError = V2KeychainAccessError.status(-25308)
        let restored = try store.loadOrCreate(
            account: account,
            candidate: Data(repeating: 9, count: 32),
            validate: validate
        )

        #expect(restored == candidate)
        #expect(access.reads.map(\.dataProtection) == [true, false, true, true])
    }

    @Test
    func installationMigrationPreservesOriginalUuidBytes() throws {
        let access = V2KeychainTestAccess(supportsLegacyFileKeychain: true)
        let original = "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE"
        access.seed(
            Data(original.utf8),
            service: service,
            account: "device-id",
            dataProtection: false
        )
        let store = V2KeychainStore(
            service: service,
            access: access
        )

        let data = try store.loadOrCreate(
            account: "device-id",
            candidate: Data("ffffffff-ffff-4fff-8fff-ffffffffffff".utf8),
            validate: { data in
                guard let value = String(data: data, encoding: .utf8),
                      UUID(uuidString: value) != nil else {
                    throw V2ControlFailure.persistenceFailed
                }
            }
        )

        #expect(String(data: data, encoding: .utf8) == original)
    }

    @Test
    func duplicateMigrationMismatchFailsClosedAndKeepsLegacy() throws {
        let access = V2KeychainTestAccess(supportsLegacyFileKeychain: true)
        let legacy = Data(repeating: 3, count: 32)
        let winner = Data(repeating: 4, count: 32)
        access.seed(legacy, service: service, account: account, dataProtection: false)
        access.addError = V2KeychainAccessError.duplicate
        access.duplicateWinner = winner
        let store = V2KeychainStore(
            service: service,
            access: access
        )

        #expect(throws: V2ControlFailure.persistenceFailed) {
            try store.loadOrCreate(
                account: account,
                candidate: Data(repeating: 8, count: 32),
                validate: { data in
                    guard data.count == 32 else { throw V2ControlFailure.persistenceFailed }
                }
            )
        }
        #expect(access.value(service: service, account: account, dataProtection: false) == legacy)
        #expect(access.value(service: service, account: account, dataProtection: true) == winner)
        #expect(access.deletes.isEmpty)
    }

    @Test
    func duplicateMigrationMismatchRemainsDeniedAfterRestart() throws {
        let access = V2KeychainTestAccess(supportsLegacyFileKeychain: true)
        let legacy = Data(repeating: 3, count: 32)
        let winner = Data(repeating: 4, count: 32)
        access.seed(legacy, service: service, account: account, dataProtection: false)
        access.addError = V2KeychainAccessError.duplicate
        access.duplicateWinner = winner
        let store = V2KeychainStore(service: service, access: access)
        let validate: @Sendable (Data) throws -> Void = { data in
            guard data.count == 32 else { throw V2ControlFailure.persistenceFailed }
        }

        #expect(throws: V2ControlFailure.persistenceFailed) {
            try store.loadOrCreate(account: account, candidate: winner, validate: validate)
        }
        access.addError = nil
        access.duplicateWinner = nil
        #expect(throws: V2ControlFailure.persistenceFailed) {
            try store.loadOrCreate(account: account, candidate: Data(repeating: 9, count: 32), validate: validate)
        }
        #expect(access.deletes.isEmpty)
    }

    @Test
    func interruptedMatchingMigrationReconcilesWithoutRotatingIdentity() throws {
        let access = V2KeychainTestAccess(supportsLegacyFileKeychain: true)
        let legacy = Data(repeating: 3, count: 32)
        access.seed(legacy, service: service, account: account, dataProtection: false)
        access.deleteError = V2KeychainAccessError.status(-50)
        let store = V2KeychainStore(service: service, access: access)
        let validate: @Sendable (Data) throws -> Void = { data in
            guard data.count == 32 else { throw V2ControlFailure.persistenceFailed }
        }

        #expect(throws: V2ControlFailure.persistenceFailed) {
            try store.loadOrCreate(account: account, candidate: Data(repeating: 9, count: 32), validate: validate)
        }
        #expect(access.value(service: service, account: account, dataProtection: true) == legacy)
        access.deleteError = nil
        let restored = try store.loadOrCreate(
            account: account,
            candidate: Data(repeating: 9, count: 32),
            validate: validate
        )
        #expect(restored == legacy)
        #expect(access.value(service: service, account: account, dataProtection: false) == nil)
    }

    @Test
    func lockedLegacyWithPrimaryFailsClosed() throws {
        let access = V2KeychainTestAccess(supportsLegacyFileKeychain: true)
        let primary = Data(repeating: 4, count: 32)
        access.seed(primary, service: service, account: account, dataProtection: true)
        access.legacyReadError = V2KeychainAccessError.status(-25308)
        let store = V2KeychainStore(service: service, access: access)

        #expect(throws: V2ControlFailure.persistenceFailed) {
            try store.loadOrCreate(
                account: account,
                candidate: Data(repeating: 9, count: 32),
                validate: { data in
                    guard data.count == 32 else { throw V2ControlFailure.persistenceFailed }
                }
            )
        }
    }

    @Test
    func identityStorePreservesLegacyEndpointSeed() async throws {
        let access = V2KeychainTestAccess(supportsLegacyFileKeychain: true)
        let store = V2KeychainStore(
            service: "dev.cmux.test.cmux-iroh-v2.endpoint-keys",
            access: access
        )
        let identity = V2Identity(
            appNamespace: "dev.cmux.test",
            buildTag: "release",
            deviceID: "device",
            environment: "production",
            projectID: "project",
            teamID: "team",
            userID: "user"
        )
        let legacyKey = V2IdentityKey()
        let digest = SHA256.hash(data: try V2WireSigningCodec().encode(identity))
            .map { String(format: "%02x", $0) }
            .joined()
        access.seed(
            legacyKey.secretKey,
            service: "dev.cmux.test.cmux-iroh-v2.endpoint-keys",
            account: digest,
            dataProtection: false
        )
        let identityStore = V2IdentityKeyStore(
            applicationNamespace: "dev.cmux.test",
            keychain: store
        )

        let restored = try await identityStore.loadOrCreate(identity: identity)

        #expect(restored.endpointID == legacyKey.endpointID)
        #expect(access.value(
            service: "dev.cmux.test.cmux-iroh-v2.endpoint-keys",
            account: digest,
            dataProtection: true
        ) == legacyKey.secretKey)
    }
}
