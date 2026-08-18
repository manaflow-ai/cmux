import CryptoKit
import Foundation
import Testing
@testable import CmuxPeerTransport

/// Identity layer: three-state secure reads, install-marker and account-scope
/// reconciliation, generation semantics, and the exact persisted format the
/// previous transport wrote (so installs keep their EndpointID).
@Suite
struct PeerIdentityTests {
    @Test
    func endpointIDDerivationMatchesTheIrohDerivation() throws {
        // The previous transport derived this EndpointID for the same secret
        // through IrohLib; CryptoKit must derive the identical value.
        let identity = try BrokerFixtures.identity()
        #expect(identity.endpointID.endpointID == BrokerFixtures.endpointID)
    }

    @Test
    func secretsMustBeExactly32Bytes() {
        #expect(throws: PeerIdentityError.invalidSecretByteCount(31)) {
            _ = try PeerSecretKey(bytes: Data(repeating: 1, count: 31))
        }
        #expect(throws: PeerIdentityError.invalidGeneration) {
            _ = try PeerEndpointIdentity(
                secretKey: PeerSecretKey(bytes: Data(repeating: 1, count: 32)),
                generation: 0
            )
        }
    }

    @Test
    func identityRemainsStableInsideOneInstallAndAccountScope() async throws {
        let harness = IdentityHarness()
        let repository = harness.repository()

        let first = try await repository.identity(accountID: "user-a", appInstanceID: "app-a")
        let second = try await repository.identity(accountID: "user-a", appInstanceID: "app-a")

        #expect(first == second)
        #expect(first.generation == 1)
        #expect(await harness.store.deleteAllCount == 1)
    }

    @Test
    func identityPersistsUnderTheExactLegacyScopeDigestAndRecordFormat() async throws {
        let harness = IdentityHarness()
        let repository = harness.repository()

        let identity = try await repository.identity(accountID: "user", appInstanceID: "app")

        // Account key: SHA-256 hex of the legacy scope transcript.
        let transcript = Data("cmux/iroh/identity-scope/v1\0user\0app".utf8)
        let expectedAccount = SHA256.hash(data: transcript)
            .map { String(format: "%02x", $0) }
            .joined()
        let contents = await harness.store.contents()
        #expect(Array(contents.keys) == [expectedAccount])

        // Record: version byte 1 + big-endian generation + 32 secret bytes.
        let record = try #require(contents[expectedAccount])
        #expect(record.count == 37)
        #expect(record[0] == 1)
        #expect(Array(record[1 ..< 5]) == [0, 0, 0, 1])
        #expect(Data(record[5...]) == identity.secretKey.bytes)
    }

    @Test
    func recordsWrittenByThePreviousTransportDecodeUnchanged() async throws {
        let harness = IdentityHarness()
        let repository = harness.repository()
        // Establish install marker and active scope, then replace the stored
        // record with a byte-exact legacy record at generation 3.
        _ = try await repository.identity(accountID: "user", appInstanceID: "app")
        let transcript = Data("cmux/iroh/identity-scope/v1\0user\0app".utf8)
        let account = SHA256.hash(data: transcript)
            .map { String(format: "%02x", $0) }
            .joined()
        let legacyRecord = Data([1, 0, 0, 0, 3]) + BrokerFixtures.secretBytes
        await harness.store.install(legacyRecord, account: account)

        let identity = try await repository.identity(accountID: "user", appInstanceID: "app")

        #expect(identity.generation == 3)
        #expect(identity.secretKey.bytes == BrokerFixtures.secretBytes)
        #expect(identity.endpointID.endpointID == BrokerFixtures.endpointID)
    }

    @Test
    func accountSwitchesRotateAndDoNotResurrectPriorKeys() async throws {
        let harness = IdentityHarness()
        let repository = harness.repository()

        let accountA = try await repository.identity(accountID: "user-a", appInstanceID: "app")
        let accountB = try await repository.identity(accountID: "user-b", appInstanceID: "app")
        let accountAAgain = try await repository.identity(accountID: "user-a", appInstanceID: "app")

        #expect(accountA.secretKey != accountB.secretKey)
        #expect(accountA.secretKey != accountAAgain.secretKey)
        #expect(await harness.store.deleteAllCount == 3)
    }

    @Test
    func missingInstallMarkerRejectsAKeyThatSurvivedUninstall() async throws {
        let harness = IdentityHarness()
        let repository = harness.repository()
        let original = try await repository.identity(accountID: "user", appInstanceID: "app")

        harness.state.set(nil, forKey: "cmux.iroh.identity.install-marker.v1")
        let afterReinstall = try await repository.identity(accountID: "user", appInstanceID: "app")

        #expect(original.secretKey != afterReinstall.secretKey)
        #expect(afterReinstall.generation == 1)
        #expect(await harness.store.deleteAllCount == 2)
    }

    @Test
    func explicitRotationIncrementsGenerationWithoutChangingScope() async throws {
        let harness = IdentityHarness()
        let repository = harness.repository()
        let original = try await repository.identity(accountID: "user", appInstanceID: "app")

        let rotated = try await repository.rotate(accountID: "user", appInstanceID: "app")
        let reloaded = try await repository.identity(accountID: "user", appInstanceID: "app")

        #expect(rotated.secretKey != original.secretKey)
        #expect(rotated.generation == 2)
        #expect(reloaded == rotated)
    }

    @Test
    func deactivationRemovesTheActiveKey() async throws {
        let harness = IdentityHarness()
        let repository = harness.repository()
        let original = try await repository.identity(accountID: "user", appInstanceID: "app")

        try await repository.deactivate()
        let replacement = try await repository.identity(accountID: "user", appInstanceID: "app")

        #expect(replacement.secretKey != original.secretKey)
        #expect(replacement.generation == 1)
    }

    @Test
    func unavailableStorePropagatesAndNeverMintsAReplacementIdentity() async throws {
        let harness = IdentityHarness()
        let repository = harness.repository()
        let original = try await repository.identity(accountID: "user", appInstanceID: "app")
        let writesBefore = await harness.store.writeCount

        await harness.store.setUnavailable(status: -25308)
        await #expect(throws: PeerIdentityError.storeUnavailable(status: -25308)) {
            _ = try await repository.identity(accountID: "user", appInstanceID: "app")
        }
        await #expect(throws: PeerIdentityError.storeUnavailable(status: -25308)) {
            _ = try await repository.rotate(accountID: "user", appInstanceID: "app")
        }
        #expect(await harness.store.writeCount == writesBefore)

        // Once the store answers again, the SAME identity comes back.
        await harness.store.setUnavailable(status: nil)
        let recovered = try await repository.identity(accountID: "user", appInstanceID: "app")
        #expect(recovered == original)
    }

    @Test
    func emptyAccountAndAppScopesAreRejected() async throws {
        let harness = IdentityHarness()
        let repository = harness.repository()

        await #expect(throws: PeerIdentityError.invalidScope) {
            _ = try await repository.identity(accountID: "", appInstanceID: "app")
        }
        await #expect(throws: PeerIdentityError.invalidScope) {
            _ = try await repository.identity(accountID: "user", appInstanceID: "")
        }
    }

    @Test
    func corruptRecordsAreRejectedNotSilentlyReplaced() async throws {
        let harness = IdentityHarness()
        let repository = harness.repository()
        _ = try await repository.identity(accountID: "user", appInstanceID: "app")
        let account = try #require(await harness.store.contents().keys.first)
        await harness.store.install(Data([9, 9, 9]), account: account)

        await #expect(throws: PeerIdentityError.corruptRecord) {
            _ = try await repository.identity(accountID: "user", appInstanceID: "app")
        }
    }
}

private final class IdentityHarness: @unchecked Sendable {
    let store = MemoryBlobStore()
    let state = MemoryInstallStateStore()
    private let entropy = CountingEntropy()

    func repository() -> PeerIdentityRepository {
        PeerIdentityRepository(
            secureStore: store,
            installState: state,
            randomBytes: { [entropy] in entropy.nextBytes() },
            marker: { [entropy] in entropy.nextMarker() }
        )
    }
}

private final class MemoryInstallStateStore: PeerInstallStateStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]

    func string(forKey key: String) -> String? {
        lock.withLock { values[key] }
    }

    func set(_ value: String?, forKey key: String) {
        lock.withLock { values[key] = value }
    }
}

private final class CountingEntropy: @unchecked Sendable {
    private let lock = NSLock()
    private var counter: UInt8 = 0

    func nextBytes() -> Data {
        lock.withLock {
            counter &+= 1
            return Data(repeating: counter, count: 32)
        }
    }

    func nextMarker() -> String {
        lock.withLock {
            counter &+= 1
            return "marker-\(counter)"
        }
    }
}
