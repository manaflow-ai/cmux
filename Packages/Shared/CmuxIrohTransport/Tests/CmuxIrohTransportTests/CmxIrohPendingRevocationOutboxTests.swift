import Foundation
import Testing
@testable import CmuxIrohTransport

@Suite("Iroh pending revocation outbox")
struct CmxIrohPendingRevocationOutboxTests {
    private let accountID = "account-a"
    private let tag = "cmux-ios-v0"
    private let bindingID = "123e4567-e89b-42d3-a456-426614174020"

    @Test("pending revocations survive recreation in device-only storage without auth tokens")
    func durableDeviceOnlyStorageContainsNoTokens() async throws {
        let store = TestSecureCredentialStore()
        let outbox = CmxIrohPendingRevocationOutbox(secureStore: store)
        let pending = try revocation()

        try await outbox.enqueue(pending)

        let recreated = CmxIrohPendingRevocationOutbox(secureStore: store)
        #expect(try await recreated.pending(accountID: accountID) == [pending])
        #expect(
            await store.observedAccessibilities()
                == [.afterFirstUnlockThisDeviceOnly]
        )
        let stored = try #require(await store.onlyStoredData())
        let encoded = String(decoding: stored, as: UTF8.self)
        #expect(!encoded.contains("access-token-secret"))
        #expect(!encoded.contains("refresh-token-secret"))
    }

    @Test(arguments: [
        CmxIrohTrustBrokerClientError.connectivity,
        .rejected(statusCode: 503, code: "unavailable"),
    ])
    func transientFailureRetainsPendingRevocation(
        _ failure: CmxIrohTrustBrokerClientError
    ) async throws {
        let store = TestSecureCredentialStore()
        let outbox = CmxIrohPendingRevocationOutbox(secureStore: store)
        let pending = try revocation()
        let broker = PendingRevocationBroker(error: failure)
        try await outbox.enqueue(pending)

        do {
            try await outbox.revokePending(
                accountID: accountID,
                beforeRegisteringTag: tag,
                using: broker
            )
            Issue.record("Expected revocation failure")
        } catch let error as CmxIrohTrustBrokerClientError {
            #expect(error == failure)
        }

        #expect(try await outbox.pending(accountID: accountID) == [pending])
        #expect(await broker.revokedBindingIDs() == [bindingID])
    }

    @Test("confirmed revocation removes only that account and drains older build tags")
    func confirmedRevocationRemovesAccountEntriesAcrossTags() async throws {
        let store = TestSecureCredentialStore()
        let outbox = CmxIrohPendingRevocationOutbox(secureStore: store)
        let current = try revocation()
        let oldTag = try CmxIrohPendingRevocation(
            accountID: accountID,
            tag: "cmux-ios-v0-old",
            bindingID: "123e4567-e89b-42d3-a456-426614174021"
        )
        let otherAccount = try CmxIrohPendingRevocation(
            accountID: "account-b",
            tag: tag,
            bindingID: "123e4567-e89b-42d3-a456-426614174022"
        )
        try await outbox.enqueue(oldTag)
        try await outbox.enqueue(current)
        try await outbox.enqueue(current)
        try await outbox.enqueue(otherAccount)
        let broker = PendingRevocationBroker()

        try await outbox.revokePending(
            accountID: accountID,
            beforeRegisteringTag: tag,
            using: broker
        )

        #expect(
            await broker.revokedBindingIDs()
                == [current.bindingID, oldTag.bindingID]
        )
        #expect(try await outbox.pending(accountID: accountID).isEmpty)
        #expect(
            try await outbox.pending(accountID: otherAccount.accountID)
                == [otherAccount]
        )
    }

    private func revocation() throws -> CmxIrohPendingRevocation {
        try CmxIrohPendingRevocation(
            accountID: accountID,
            tag: tag,
            bindingID: bindingID
        )
    }
}

private actor PendingRevocationBroker: CmxIrohBindingRevoking {
    private let error: CmxIrohTrustBrokerClientError?
    private var bindingIDs: [String] = []

    init(error: CmxIrohTrustBrokerClientError? = nil) {
        self.error = error
    }

    func revoke(bindingID: String) throws {
        bindingIDs.append(bindingID)
        if let error { throw error }
    }

    func revokedBindingIDs() -> [String] { bindingIDs }
}
