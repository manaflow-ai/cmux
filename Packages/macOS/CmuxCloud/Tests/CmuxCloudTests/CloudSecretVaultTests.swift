@testable import CmuxCloud
import CryptoKit
import Foundation
import os
import Testing

/// A settable wall clock for vault timestamps.
final class CloudSecretTestClock: @unchecked Sendable {
    // @unchecked: the only state is behind the lock.
    private let lock = OSAllocatedUnfairLock(initialState: Date(timeIntervalSince1970: 1_000))

    var now: Date { lock.withLock { $0 } }

    func advance(_ seconds: TimeInterval) {
        lock.withLock { $0 = $0.addingTimeInterval(seconds) }
    }
}

/// Secret storage, change reporting, fingerprints and the persisted document.
@Suite struct CloudSecretVaultTests {
    let storage = InMemoryCloudSecretVaultStorage()
    let clock = CloudSecretTestClock()

    func makeVault() -> CloudSecretVault {
        let clock = clock
        return CloudSecretVault(storage: storage, now: { clock.now })
    }

    @Test
    func setReportsAddedUpdatedUnchangedAndKeepsTimestamps() async throws {
        let vault = makeVault()
        let first = try await vault.set(
            [CloudSecretInput(name: "ANTHROPIC_API_KEY", value: "sk-one"), CloudSecretInput(name: "OPENAI_API_KEY", value: "sk-two")],
            scope: .all,
            source: .manual
        )
        #expect(first.map(\.kind) == [.added, .added])
        clock.advance(60)
        let second = try await vault.set(
            [CloudSecretInput(name: "ANTHROPIC_API_KEY", value: "sk-one"), CloudSecretInput(name: "OPENAI_API_KEY", value: "sk-changed")],
            scope: .all,
            source: .dotenv(".env")
        )
        #expect(second == [
            CloudSecretChange(name: "ANTHROPIC_API_KEY", scope: .all, kind: .unchanged),
            CloudSecretChange(name: "OPENAI_API_KEY", scope: .all, kind: .updated)
        ])
        let records = try await vault.records()
        let anthropic = try #require(records.first { $0.name == "ANTHROPIC_API_KEY" })
        let openAI = try #require(records.first { $0.name == "OPENAI_API_KEY" })
        #expect(anthropic.updatedAt == Date(timeIntervalSince1970: 1_000))
        #expect(anthropic.source == .manual)
        #expect(openAI.createdAt == Date(timeIntervalSince1970: 1_000))
        #expect(openAI.updatedAt == Date(timeIntervalSince1970: 1_060))
        #expect(openAI.source == .dotenv(".env"))
    }

    @Test
    func previewMatchesSetAndNeverSaves() async throws {
        let vault = makeVault()
        try await vault.set([CloudSecretInput(name: "KEEP", value: "1"), CloudSecretInput(name: "CHANGE", value: "1")], scope: .all, source: .manual)
        let saved = try storage.load()
        let inputs = [
            CloudSecretInput(name: "KEEP", value: "1"),
            CloudSecretInput(name: "CHANGE", value: "2"),
            CloudSecretInput(name: "NEW", value: "x"),
            CloudSecretInput(name: "NEW", value: "y")
        ]
        let preview = try await vault.preview(inputs, scope: .all)
        #expect(preview == [
            CloudSecretChange(name: "KEEP", scope: .all, kind: .unchanged),
            CloudSecretChange(name: "CHANGE", scope: .all, kind: .updated),
            CloudSecretChange(name: "NEW", scope: .all, kind: .added)
        ])
        #expect(try storage.load() == saved)
        #expect(try await vault.records().map(\.name).sorted() == ["CHANGE", "KEEP"])

        // Another scope is compared on its own.
        #expect(try await vault.preview([CloudSecretInput(name: "KEEP", value: "1")], scope: .machine("m1")).map(\.kind) == [.added])

        #expect(try await vault.set(inputs, scope: .all, source: .manual) == preview)
    }

    @Test
    func previewValidatesLikeSet() async throws {
        let vault = makeVault()
        await #expect(throws: CloudSecretValidationError.reservedName("PATH")) {
            try await vault.preview([CloudSecretInput(name: "PATH", value: "/bin")], scope: .all)
        }
        await #expect(throws: CloudSecretValidationError.multilineValue("A")) {
            try await vault.preview([CloudSecretInput(name: "A", value: "1\n2")], scope: .all)
        }
        #expect(try storage.load() == nil)
    }

    @Test
    func unchangedOnlySetDoesNotRewriteStorage() async throws {
        let vault = makeVault()
        try await vault.set([CloudSecretInput(name: "A", value: "1")], scope: .all, source: .manual)
        let saved = try storage.load()
        clock.advance(10)
        #expect(try await vault.set([CloudSecretInput(name: "A", value: "1")], scope: .all, source: .shell).map(\.kind) == [.unchanged])
        #expect(try storage.load() == saved)
    }

    @Test
    func repeatedNameInOneSetKeepsLastValue() async throws {
        let vault = makeVault()
        let changes = try await vault.set(
            [CloudSecretInput(name: "A", value: "first"), CloudSecretInput(name: "A", value: "second")],
            scope: .all,
            source: .manual
        )
        #expect(changes == [CloudSecretChange(name: "A", scope: .all, kind: .added)])
        let plan = try await vault.plan(machineID: "m1")
        #expect(plan.toSend == [CloudEnvDelivery.Entry(key: "A", value: "second")])
    }

    @Test
    func nameStoredBeforeItBecameReservedIsNeverSentAndADeliveredCopyIsRemoved() async throws {
        // A vault written by an older build can hold a name that is reserved now
        // (`ENV`, `IFS`, `LD_AUDIT`): the machine refuses it, so sync must not send it.
        func entry(_ name: String, _ value: String) -> CloudSecretVaultDocument.Entry {
            CloudSecretVaultDocument.Entry(
                record: CloudSecretRecord(
                    name: name, scope: .all, fingerprint: "0000000\(name.count)",
                    createdAt: Date(timeIntervalSince1970: 1), updatedAt: Date(timeIntervalSince1970: 1), source: .manual
                ),
                value: value
            )
        }
        let document = CloudSecretVaultDocument(
            secrets: [entry("ENV", "/tmp/rc"), entry("LD_AUDIT", "x.so"), entry("GH_TOKEN", "ghp_x")],
            ledger: [CloudSecretDelivery(machineID: "m1", delivered: ["ENV": "00000003"])]
        )
        let plan = CloudSecretVault.plan(machineID: "m1", document: document)
        #expect(plan.toSend == [CloudEnvDelivery.Entry(key: "GH_TOKEN", value: "ghp_x")])
        #expect(plan.toRemove == ["ENV"])
        #expect(plan.effective.keys.sorted() == ["GH_TOKEN"])
        // And it stays removable: removal checks the name's shape only.
        try CloudSecretInput.validateNameSyntax("ENV")
        #expect(throws: CloudSecretValidationError.invalidName("1ENV")) { try CloudSecretInput.validateNameSyntax("1ENV") }
    }

    @Test
    func fingerprintIsEightHexKeyedAndStableAcrossReloads() async throws {
        let vault = makeVault()
        try await vault.set([CloudSecretInput(name: "A", value: "same")], scope: .all, source: .manual)
        try await vault.set([CloudSecretInput(name: "A", value: "same")], scope: .machine("m1"), source: .manual)
        try await vault.set([CloudSecretInput(name: "B", value: "other")], scope: .all, source: .manual)
        let records = try await vault.records()
        for record in records {
            #expect(record.fingerprint.range(of: "^[0-9a-f]{8}\\z", options: .regularExpression) != nil)
        }
        let fingerprints = Dictionary(grouping: records, by: \.name)
        #expect(Set(fingerprints["A"]?.map(\.fingerprint) ?? []).count == 1)
        #expect(fingerprints["A"]?.first?.fingerprint != fingerprints["B"]?.first?.fingerprint)

        let reloaded = CloudSecretVault(storage: storage)
        #expect(try await reloaded.records() == records)

        // A different vault key gives a different fingerprint for the same value.
        let otherVault = CloudSecretVault(storage: InMemoryCloudSecretVaultStorage())
        try await otherVault.set([CloudSecretInput(name: "A", value: "same")], scope: .all, source: .manual)
        let other = try await otherVault.records()
        #expect(other.first?.fingerprint != fingerprints["A"]?.first?.fingerprint)
    }

    @Test
    func fingerprintMatchesHMACPrefix() throws {
        let key = Data(repeating: 7, count: 32)
        let fingerprint = CloudSecretVault.fingerprint("value", key: SymmetricKey(data: key))
        #expect(fingerprint.count == 8)
        #expect(fingerprint == CloudSecretVault.fingerprint("value", key: SymmetricKey(data: key)))
        #expect(fingerprint != CloudSecretVault.fingerprint("value2", key: SymmetricKey(data: key)))
    }

    @Test
    func recordsSortByScopeRankTargetAndName() async throws {
        let vault = makeVault()
        try await vault.set([CloudSecretInput(name: "Z", value: "1")], scope: .machine("m1"), source: .manual)
        try await vault.set([CloudSecretInput(name: "B", value: "1"), CloudSecretInput(name: "A", value: "1")], scope: .all, source: .manual)
        try await vault.set([CloudSecretInput(name: "C", value: "1")], scope: .project("github.com/b/b"), source: .manual)
        try await vault.set([CloudSecretInput(name: "D", value: "1")], scope: .project("github.com/a/a"), source: .manual)
        let order = try await vault.records().map { "\($0.scope.wireValue)/\($0.name)" }
        #expect(order == ["all/A", "all/B", "project:github.com/a/a/D", "project:github.com/b/b/C", "machine:m1/Z"])
    }

    @Test
    func removeReportsOnlyStoredNames() async throws {
        let vault = makeVault()
        try await vault.set([CloudSecretInput(name: "A", value: "1"), CloudSecretInput(name: "B", value: "2")], scope: .all, source: .manual)
        let changes = try await vault.remove(names: ["A", "MISSING"], scope: .all)
        #expect(changes == [CloudSecretChange(name: "A", scope: .all, kind: .removed)])
        #expect(try await vault.remove(names: ["B"], scope: .machine("m1")).isEmpty)
        #expect(try await vault.records().map(\.name) == ["B"])
    }

    @Test
    func persistedDocumentIsVersionedWithRandomKey() async throws {
        let vault = makeVault()
        #expect(try storage.load() == nil)
        try await vault.set([CloudSecretInput(name: "A", value: "1")], scope: .all, source: .shell)
        let data = try #require(try storage.load())
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["version"] as? Int == 1)
        let key = try #require(Data(base64Encoded: json["hmacKey"] as? String ?? ""))
        #expect(key.count == 32)
        let secrets = try #require(json["secrets"] as? [[String: Any]])
        let record = try #require(secrets.first?["record"] as? [String: Any])
        #expect(record["scope"] as? String == "all")
        #expect(record["source"] as? String == "shell")
    }

    @Test
    func newerVersionIsRefusedAndLeftUntouched() async throws {
        let newer = Data(#"{"version":2,"hmacKey":"","secrets":[],"ledger":[],"future":true}"#.utf8)
        let storage = InMemoryCloudSecretVaultStorage(data: newer)
        let vault = CloudSecretVault(storage: storage)
        await #expect(throws: CloudSecretVaultError.unsupportedVersion(2)) {
            try await vault.records()
        }
        await #expect(throws: CloudSecretVaultError.unsupportedVersion(2)) {
            try await vault.set([CloudSecretInput(name: "A", value: "1")], scope: .all, source: .manual)
        }
        #expect(try storage.load() == newer)
    }

    @Test
    func corruptDocumentIsRefusedAndLeftUntouched() async throws {
        let corrupt = Data("not json".utf8)
        let storage = InMemoryCloudSecretVaultStorage(data: corrupt)
        let vault = CloudSecretVault(storage: storage)
        await #expect(throws: CloudSecretVaultError.corrupt) {
            try await vault.records()
        }
        #expect(try storage.load() == corrupt)
    }

    @Test
    func emptyStorageReadsAsEmptyVault() async throws {
        let vault = makeVault()
        #expect(try await vault.records().isEmpty)
        #expect(try await vault.deliveries().isEmpty)
        #expect(try await vault.plan(machineID: "m1").isNoop)
    }

    @Test
    func storageFailureSurfacesAndKeepsPreviousState() async throws {
        let storage = FailingCloudSecretStorage()
        let vault = CloudSecretVault(storage: storage)
        await #expect(throws: CloudSecretVaultStorageError.keychain(-25_308)) {
            try await vault.set([CloudSecretInput(name: "A", value: "1")], scope: .all, source: .manual)
        }
        #expect(try await vault.records().isEmpty)
    }
}

/// Storage whose saves always fail, as a locked Keychain would.
private struct FailingCloudSecretStorage: CloudSecretVaultStorage {
    func load() throws -> Data? { nil }
    func save(_ data: Data) throws { throw CloudSecretVaultStorageError.keychain(-25_308) }
    func delete() throws {}
}
