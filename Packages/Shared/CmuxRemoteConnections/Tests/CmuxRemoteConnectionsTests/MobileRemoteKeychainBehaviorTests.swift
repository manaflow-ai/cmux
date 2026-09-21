import Foundation
import Testing
@testable import CmuxRemoteConnections

@Suite struct MobileRemoteKeychainBehaviorTests {
    @Test func supportsInsertReadUpdateAndDeleteWithOpaqueScope() async throws {
        let backend = MobileRemoteKeychainTestBackend()
        let store = MobileRemoteKeychainSecretStore(
            namespace: try namespace(), backend: backend
        )
        let scope = try scope()
        let original = MobileRemoteSecretValue(text: "synthetic-password")
        let replacement = MobileRemoteSecretValue(text: "replacement-password")

        try await store.insert(
            original, scope: scope, protection: .whenUnlockedThisDeviceOnly
        )
        #expect(try await store.read(scope: scope).bytes == original.bytes)
        try await store.updateValue(replacement, scope: scope)
        #expect(try await store.read(scope: scope).bytes == replacement.bytes)
        try await store.delete(scope: scope)
        await #expect(throws: MobileRemoteSecretStoreError.itemNotFound) {
            _ = try await store.read(scope: scope)
        }
    }

    @Test func exactScopePreventsCrossAccountVaultAndItemAccess() async throws {
        let backend = MobileRemoteKeychainTestBackend()
        let store = MobileRemoteKeychainSecretStore(
            namespace: try namespace(), backend: backend
        )
        let first = try scope()
        let otherAccount = try MobileRemoteSecretScope(
            accountID: "different-account", vaultID: first.vaultID, itemID: first.itemID
        )
        let otherVault = try MobileRemoteSecretScope(
            accountID: first.accountID, vaultID: UUID(), itemID: first.itemID
        )
        let otherItem = try MobileRemoteSecretScope(
            accountID: first.accountID, vaultID: first.vaultID, itemID: UUID()
        )
        try await store.insert(
            MobileRemoteSecretValue(text: "only-for-first-scope"),
            scope: first,
            protection: .whenUnlockedThisDeviceOnly
        )

        for candidate in [otherAccount, otherVault, otherItem] {
            await #expect(throws: MobileRemoteSecretStoreError.itemNotFound) {
                _ = try await store.read(scope: candidate)
            }
            await #expect(throws: MobileRemoteSecretStoreError.itemNotFound) {
                try await store.delete(scope: candidate)
            }
        }
        #expect(try await store.read(scope: first).bytes == Data("only-for-first-scope".utf8))
    }

    @Test func duplicateInsertIsRejectedAndDoesNotDowngradePolicy() async throws {
        let backend = MobileRemoteKeychainTestBackend()
        let store = MobileRemoteKeychainSecretStore(
            namespace: try namespace(), backend: backend
        )
        let scope = try scope()
        try await store.insert(
            MobileRemoteSecretValue(text: "protected"),
            scope: scope,
            protection: .whenUnlockedThisDeviceOnlyBiometryCurrentSet
        )
        await #expect(throws: MobileRemoteSecretStoreError.itemAlreadyExists) {
            try await store.insert(
                MobileRemoteSecretValue(text: "attempted-downgrade"),
                scope: scope,
                protection: .whenUnlockedThisDeviceOnly
            )
        }

        try await store.updateValue(
            MobileRemoteSecretValue(text: "updated"), scope: scope
        )
        #expect(await backend.protection(for: scope)
            == .whenUnlockedThisDeviceOnlyBiometryCurrentSet)
        #expect(try await store.read(scope: scope).bytes == Data("updated".utf8))
    }

    @Test func preservesTypedSecurityFailures() async throws {
        let backend = MobileRemoteKeychainTestBackend()
        let store = MobileRemoteKeychainSecretStore(
            namespace: try namespace(), backend: backend
        )
        let scope = try scope()
        for failure in [
            MobileRemoteSecretStoreError.deviceLocked(-25316),
            .interactionNotAllowed(-25308),
            .missingEntitlement(-34018),
            .corruptedItem(-26275),
        ] {
            await backend.setReadFailure(failure)
            await #expect(throws: failure) {
                _ = try await store.read(scope: scope)
            }
        }
    }

    @Test func validatesInteractiveReasonBeforeTouchingBackend() async throws {
        let backend = MobileRemoteKeychainTestBackend()
        let store = MobileRemoteKeychainSecretStore(
            namespace: try namespace(), backend: backend
        )
        let scope = try scope()
        await #expect(throws: MobileRemoteSecretStoreError.invalidLocalizedReason) {
            _ = try await store.read(
                scope: scope,
                interaction: .userInitiated(localizedReason: " \n")
            )
        }
        #expect(await backend.readCount == 0)
    }

    @Test func cancelledReadNeverReturnsCredentialBytes() async throws {
        let backend = MobileRemoteKeychainTestBackend()
        let store = MobileRemoteKeychainSecretStore(
            namespace: try namespace(), backend: backend
        )
        let scope = try scope()
        await backend.setDelayedRead(value: Data("must-not-escape".utf8))

        let readTask = Task {
            try await store.read(scope: scope)
        }
        await backend.waitUntilReadStarted()
        readTask.cancel()
        await backend.releaseDelayedRead()
        await #expect(throws: CancellationError.self) {
            _ = try await readTask.value
        }
    }

    private func namespace() throws -> MobileRemoteKeychainNamespace {
        try MobileRemoteKeychainNamespace(accessGroup: "TESTTEAM.dev.cmux.remote.tests")
    }

    private func scope() throws -> MobileRemoteSecretScope {
        try MobileRemoteSecretScope(
            accountID: "account-for-tests", vaultID: UUID(), itemID: UUID()
        )
    }
}

private actor MobileRemoteKeychainTestBackend: MobileRemoteKeychainBackend {
    private struct Record: Sendable {
        let value: Data
        let protection: MobileRemoteSecretProtection
    }

    private var records: [MobileRemoteSecretScope: Record] = [:]
    private var readFailure: MobileRemoteSecretStoreError?
    private var delayedReadValue: Data?
    private var delayedReadWaiter: CheckedContinuation<Void, Never>?
    private var delayedReadStarted = false
    private var delayedReadStartedWaiter: CheckedContinuation<Void, Never>?
    private(set) var readCount = 0

    func insert(
        value: Data,
        scope: MobileRemoteSecretScope,
        protection: MobileRemoteSecretProtection
    ) async throws {
        guard records[scope] == nil else {
            throw MobileRemoteSecretStoreError.itemAlreadyExists
        }
        records[scope] = Record(value: value, protection: protection)
    }

    func read(
        scope: MobileRemoteSecretScope,
        interaction: MobileRemoteSecretInteraction
    ) async throws -> Data {
        readCount += 1
        if let readFailure { throw readFailure }
        if let delayedReadValue {
            delayedReadStarted = true
            delayedReadStartedWaiter?.resume()
            delayedReadStartedWaiter = nil
            await withCheckedContinuation { continuation in
                delayedReadWaiter = continuation
            }
            return delayedReadValue
        }
        guard let record = records[scope] else {
            throw MobileRemoteSecretStoreError.itemNotFound
        }
        return record.value
    }

    func updateValue(
        value: Data,
        scope: MobileRemoteSecretScope,
        interaction: MobileRemoteSecretInteraction
    ) async throws {
        guard let record = records[scope] else {
            throw MobileRemoteSecretStoreError.itemNotFound
        }
        records[scope] = Record(value: value, protection: record.protection)
    }

    func delete(
        scope: MobileRemoteSecretScope,
        interaction: MobileRemoteSecretInteraction
    ) async throws {
        guard records.removeValue(forKey: scope) != nil else {
            throw MobileRemoteSecretStoreError.itemNotFound
        }
    }

    func protection(for scope: MobileRemoteSecretScope) -> MobileRemoteSecretProtection? {
        records[scope]?.protection
    }

    func setReadFailure(_ failure: MobileRemoteSecretStoreError?) {
        readFailure = failure
    }

    func setDelayedRead(value: Data) {
        delayedReadValue = value
    }

    func waitUntilReadStarted() async {
        if delayedReadStarted {
            return
        }
        await withCheckedContinuation { continuation in
            delayedReadStartedWaiter = continuation
        }
    }

    func releaseDelayedRead() {
        delayedReadWaiter?.resume()
        delayedReadWaiter = nil
        delayedReadValue = nil
    }
}
