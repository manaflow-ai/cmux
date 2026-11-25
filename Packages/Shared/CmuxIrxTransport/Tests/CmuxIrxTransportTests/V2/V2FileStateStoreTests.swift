import Foundation
import CryptoKit
import Testing
@testable import CmuxIrxTransport

struct V2FileStateStoreTests {
    @Test(arguments: [V2Platform.mac, .ios])
    func persistedStateDoesNotExposeCredentialsOrEndpointIDs(platform: V2Platform) async throws {
        let files = FileManager()
        let root = files.temporaryDirectory.appendingPathComponent("cmux-v2-private-state-\(UUID().uuidString)")
        defer { try? files.removeItem(at: root) }
        let identity = V2Identity(appNamespace: "com.cmux.test", buildTag: "test", deviceID: "device",
            environment: "test", projectID: "project", teamID: "team", userID: "user")
        let key = V2IdentityKey()
        let endpoint = key.endpointID
        var state = V2CachedState(identity: identity)
        state.ticket = V2Ticket(expiresAt: 3600, refreshAfter: 3300, token: "private-api-ticket")
        state.device = V2DeviceRecord(descriptor: V2DeviceDescriptor(endpointID: endpoint, identity: identity,
            identityGeneration: 1, metadata: V2DeviceMetadata(appVersion: "1", capabilities: [],
                displayName: "Private Mac", pairingEnabled: true, platform: platform, relayURLs: [])),
            deviceRecordID: "record", revision: 1, revoked: false)
        let store = V2FileStateStore(rootDirectory: root, fileManager: FileManager(), identityKey: key)
        try await store.save(state)
        #expect(try await store.load(identity: identity) == state)
        let reopened = V2FileStateStore(rootDirectory: root, fileManager: FileManager(),
            identityKey: try V2IdentityKey(secretKey: key.secretKey))
        #expect(try await reopened.load(identity: identity) == state)
        let directory = root.appendingPathComponent("cmux-iroh-v2/state")
        let entries = try files.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        for file in entries {
            let bytes = try Data(contentsOf: file)
            #expect(bytes.range(of: Data(endpoint.utf8)) == nil)
            #expect(bytes.range(of: Data("private-api-ticket".utf8)) == nil)
            #expect(bytes.range(of: Data("Private Mac".utf8)) == nil)
        }
    }

    @Test func replacesOneFilePerScopeAndIgnoresLegacyState() async throws {
        let files = FileManager()
        let root = files.temporaryDirectory.appendingPathComponent("cmux-v2-state-\(UUID().uuidString)")
        try files.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: root) }
        let legacy = root.appendingPathComponent("iroh-state.json")
        let oldBytes = Data("{\"legacy\":true}".utf8)
        try oldBytes.write(to: legacy)
        let identity = V2Identity(appNamespace: "com.cmux.test", buildTag: "test", deviceID: "device", environment: "test", projectID: "project", teamID: "team-one", userID: "user")
        let other = V2Identity(appNamespace: "com.cmux.test", buildTag: "test", deviceID: "device", environment: "test", projectID: "project", teamID: "team-two", userID: "user")
        let store = V2FileStateStore(rootDirectory: root, fileManager: FileManager(), identityKey: V2IdentityKey())
        #expect(try await store.load(identity: identity) == nil)
        var state = V2CachedState(identity: identity)
        for index in 0..<10 {
            state.ticket = V2Ticket(expiresAt: 3600, refreshAfter: 3300, token: "ticket-\(index)")
            try await store.save(state)
        }
        #expect(try await store.load(identity: identity)?.ticket?.token == "ticket-9")
        #expect(try await store.load(identity: other) == nil)
        #expect(try Data(contentsOf: legacy) == oldBytes)
        let directory = root.appendingPathComponent("cmux-iroh-v2/state")
        let entries = try files.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        #expect(entries.count == 1)
        let attributes = try files.attributesOfItem(atPath: entries[0].path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test func plaintextMigrationPreservesStateAndRemovesOnlyItsOwnFile() async throws {
        let files = FileManager()
        let root = files.temporaryDirectory.appendingPathComponent("cmux-v2-migration-\(UUID().uuidString)")
        defer { try? files.removeItem(at: root) }
        let state = migrationState()
        let legacy = try location(root: root, identity: state.identity, suffix: "json")
        try files.createDirectory(at: legacy.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(state).write(to: legacy)
        let unrelated = legacy.deletingLastPathComponent().appendingPathComponent("another-scope.json")
        try Data("untouched".utf8).write(to: unrelated)
        let key = V2IdentityKey()
        let store = V2FileStateStore(rootDirectory: root, fileManager: FileManager(), identityKey: key)
        #expect(try await store.load(identity: state.identity) == state)
        #expect(!files.fileExists(atPath: legacy.path))
        #expect(try String(contentsOf: unrelated, encoding: .utf8) == "untouched")
        let reopened = V2FileStateStore(rootDirectory: root, fileManager: FileManager(), identityKey: key)
        #expect(try await reopened.load(identity: state.identity) == state)
        // Resume after a crash between the encrypted write and plaintext deletion.
        var stale = state
        stale.authorityRevoked = false
        try JSONEncoder().encode(stale).write(to: legacy)
        #expect(try await reopened.load(identity: state.identity) == state)
        #expect(!files.fileExists(atPath: legacy.path))
    }

    @Test func wrongKeyTamperingAndScopeSwapsCannotRestoreAuthorityOrFallBackToPlaintext() async throws {
        let files = FileManager()
        let root = files.temporaryDirectory.appendingPathComponent("cmux-v2-tamper-\(UUID().uuidString)")
        defer { try? files.removeItem(at: root) }
        let state = migrationState()
        let key = V2IdentityKey()
        let store = V2FileStateStore(rootDirectory: root, fileManager: FileManager(), identityKey: key)
        try await store.save(state)
        let sealed = try location(root: root, identity: state.identity, suffix: "sealed")
        let original = try Data(contentsOf: sealed)
        let wrongKey = V2FileStateStore(rootDirectory: root, fileManager: FileManager(), identityKey: V2IdentityKey())
        #expect(try await wrongKey.load(identity: state.identity) == nil)
        let other = V2Identity(appNamespace: "other", buildTag: "test", deviceID: "device",
            environment: "test", projectID: "project", teamID: "other-team", userID: "other-user")
        try original.write(to: location(root: root, identity: other, suffix: "sealed"))
        #expect(try await store.load(identity: other) == nil)
        var tampered = original
        tampered[tampered.count - 1] ^= 1
        try tampered.write(to: sealed)
        let legacy = try location(root: root, identity: state.identity, suffix: "json")
        try JSONEncoder().encode(state).write(to: legacy)
        #expect(try await store.load(identity: state.identity) == nil)
        // No silent recovery through the superseded plaintext authority.
        #expect(try Data(contentsOf: sealed) == tampered)
    }

    @Test func migrationRejectsForeignScopeAndKeepsPlaintextWhenSaveFails() async throws {
        let files = FileManager()
        let root = files.temporaryDirectory.appendingPathComponent("cmux-v2-failed-migration-\(UUID().uuidString)")
        defer { try? files.removeItem(at: root) }
        let state = migrationState()
        let legacy = try location(root: root, identity: state.identity, suffix: "json")
        try files.createDirectory(at: legacy.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = try JSONEncoder().encode(state)
        try original.write(to: legacy)
        let store = V2FileStateStore(rootDirectory: root, fileManager: FileManager(), identityKey: V2IdentityKey())
        let other = V2Identity(appNamespace: "other", buildTag: "test", deviceID: "device",
            environment: "test", projectID: "project", teamID: "other-team", userID: "other-user")
        try original.write(to: location(root: root, identity: other, suffix: "json"))
        await #expect(throws: V2ControlFailure.scopeMismatch) { try await store.load(identity: other) }
        // A directory at the destination makes an atomic file replacement fail.
        let blocked = try location(root: root, identity: state.identity, suffix: "sealed")
        try files.createDirectory(at: blocked, withIntermediateDirectories: false)
        await #expect(throws: (any Error).self) { try await store.save(state) }
        #expect(try Data(contentsOf: legacy) == original)
    }

    private func migrationState() -> V2CachedState {
        var state = V2CachedState(identity: V2Identity(appNamespace: "com.cmux.test", buildTag: "test",
            deviceID: "device", environment: "test", projectID: "project", teamID: "team", userID: "user"))
        state.ticket = V2Ticket(expiresAt: 3600, refreshAfter: 3300, token: "migration-ticket")
        state.authorityRevoked = true
        return state
    }

    private func location(root: URL, identity: V2Identity, suffix: String) throws -> URL {
        let digest = SHA256.hash(data: try V2WireSigningCodec().encode(identity))
            .map { String(format: "%02x", $0) }.joined()
        return root.appendingPathComponent("cmux-iroh-v2/state/\(digest).\(suffix)")
    }
}
