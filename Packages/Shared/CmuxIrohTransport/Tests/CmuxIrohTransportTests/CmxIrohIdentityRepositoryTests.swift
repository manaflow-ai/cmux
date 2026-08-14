import Foundation
import Testing
@testable import CmuxIrohTransport

@Suite("Iroh identity repository")
struct CmxIrohIdentityRepositoryTests {
    @Test("identity remains stable inside one install and account scope")
    func stableIdentity() async throws {
        let harness = IdentityHarness()
        let repository = harness.repository()

        let first = try await repository.identity(accountID: "user-a", appInstanceID: "app-a")
        let second = try await repository.identity(accountID: "user-a", appInstanceID: "app-a")

        #expect(first == second)
        #expect(first.generation == 1)
        #expect(harness.secure.deleteAllCount == 1)
    }

    @Test("account switches rotate and do not resurrect prior keys")
    func accountSwitchRotates() async throws {
        let harness = IdentityHarness()
        let repository = harness.repository()

        let accountA = try await repository.identity(accountID: "user-a", appInstanceID: "app")
        let accountB = try await repository.identity(accountID: "user-b", appInstanceID: "app")
        let accountAAgain = try await repository.identity(accountID: "user-a", appInstanceID: "app")

        #expect(accountA.secretKey != accountB.secretKey)
        #expect(accountA.secretKey != accountAAgain.secretKey)
        #expect(harness.secure.deleteAllCount == 3)
    }

    @Test("missing install marker rejects a key that survived uninstall")
    func reinstallRotatesSurvivingKey() async throws {
        let harness = IdentityHarness()
        let repository = harness.repository()
        let original = try await repository.identity(accountID: "user", appInstanceID: "app")

        harness.state.removeInstallMarker()
        let afterReinstall = try await repository.identity(accountID: "user", appInstanceID: "app")

        #expect(original.secretKey != afterReinstall.secretKey)
        #expect(afterReinstall.generation == 1)
        #expect(harness.secure.deleteAllCount == 2)
    }

    @Test("explicit rotation increments generation without changing scope")
    func explicitRotationIncrementsGeneration() async throws {
        let harness = IdentityHarness()
        let repository = harness.repository()
        let original = try await repository.identity(accountID: "user", appInstanceID: "app")

        let rotated = try await repository.rotate(accountID: "user", appInstanceID: "app")
        let reloaded = try await repository.identity(accountID: "user", appInstanceID: "app")

        #expect(rotated.secretKey != original.secretKey)
        #expect(rotated.generation == 2)
        #expect(reloaded == rotated)
    }

    @Test("deactivation removes the active key")
    func deactivationRemovesKey() async throws {
        let harness = IdentityHarness()
        let repository = harness.repository()
        let original = try await repository.identity(accountID: "user", appInstanceID: "app")

        try await repository.deactivate()
        let replacement = try await repository.identity(accountID: "user", appInstanceID: "app")

        #expect(replacement.secretKey != original.secretKey)
        #expect(replacement.generation == 1)
    }

    @Test("empty account and app scopes are rejected")
    func invalidScopes() async throws {
        let harness = IdentityHarness()
        let repository = harness.repository()

        await #expect(throws: CmxIrohIdentityRepositoryError.invalidScope) {
            try await repository.identity(accountID: "", appInstanceID: "app")
        }
        await #expect(throws: CmxIrohIdentityRepositoryError.invalidScope) {
            try await repository.identity(accountID: "user", appInstanceID: "")
        }
    }
}

private final class IdentityHarness: @unchecked Sendable {
    let secure = TestSecureIdentityStore()
    let state = TestInstallStateStore()
    private let entropy = TestIdentityEntropy()

    func repository() -> CmxIrohIdentityRepository {
        CmxIrohIdentityRepository(
            secureStore: secure,
            installState: state,
            randomBytes: { [entropy] in entropy.nextBytes() },
            marker: { [entropy] in entropy.nextMarker() }
        )
    }
}

private final class TestSecureIdentityStore: CmxIrohSecureIdentityStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var records: [String: Data] = [:]
    private var storedDeleteAllCount = 0

    var deleteAllCount: Int {
        lock.withLock { storedDeleteAllCount }
    }

    func read(account: String) -> Data? {
        lock.withLock { records[account] }
    }

    func write(_ data: Data, account: String) {
        lock.withLock { records[account] = data }
    }

    func delete(account: String) {
        _ = lock.withLock { records.removeValue(forKey: account) }
    }

    func deleteAll() {
        lock.withLock {
            records.removeAll()
            storedDeleteAllCount += 1
        }
    }
}

private final class TestInstallStateStore: CmxIrohInstallStateStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]

    func string(forKey key: String) -> String? {
        lock.withLock { values[key] }
    }

    func set(_ value: String?, forKey key: String) {
        lock.withLock { values[key] = value }
    }

    func removeInstallMarker() {
        _ = lock.withLock { values.removeValue(forKey: "cmux.iroh.identity.install-marker.v1") }
    }
}

private final class TestIdentityEntropy: @unchecked Sendable {
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
