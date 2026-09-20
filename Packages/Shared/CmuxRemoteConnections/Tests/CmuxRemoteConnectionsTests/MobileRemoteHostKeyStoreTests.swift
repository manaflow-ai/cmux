import Foundation
import Testing
@testable import CmuxRemoteConnections

@Suite struct MobileRemoteHostKeyStoreTests {
    @Test func askAndStrictFailClosedUntilTheUserRecordsAnExactKey() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("host-\(UUID().uuidString).json")
        let profileID = UUID()
        let challenge = try MobileRemoteSSHHostKeyChallenge(
            profileID: profileID, algorithm: "ssh-ed25519", fingerprint: "SHA256:one"
        )
        let store = try MobileRemoteHostKeyStore(databaseURL: url, accountID: "account")
        #expect(await store.decision(for: challenge, policy: .ask) == .reject)
        #expect(await store.decision(for: challenge, policy: .strict) == .reject)
        try await store.record(challenge)
        #expect(await store.decision(for: challenge, policy: .ask) == .accept)
        #expect(await store.decision(for: challenge, policy: .strict) == .accept)
        let changed = try MobileRemoteSSHHostKeyChallenge(
            profileID: profileID, algorithm: "ssh-ed25519", fingerprint: "SHA256:two"
        )
        #expect(await store.decision(for: changed, policy: .ask) == .reject)
    }

    @Test func changedAlgorithmCannotOverwriteAndReopenKeepsExactTrust() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("host-\(UUID().uuidString).json")
        let profileID = UUID()
        let challenge = try MobileRemoteSSHHostKeyChallenge(
            profileID: profileID, algorithm: "ssh-ed25519", fingerprint: "SHA256:one"
        )
        let store = try MobileRemoteHostKeyStore(databaseURL: url, accountID: "account")
        try await store.record(challenge)
        let replacement = try MobileRemoteSSHHostKeyChallenge(
            profileID: profileID, algorithm: "rsa-sha2-512", fingerprint: "SHA256:one"
        )
        await #expect(throws: MobileRemoteHostKeyStoreError.corruptStore) {
            try await store.record(replacement)
        }
        let reopened = try MobileRemoteHostKeyStore(databaseURL: url, accountID: "account")
        #expect(await reopened.observation(for: profileID)?.algorithm == "ssh-ed25519")
        #expect(throws: MobileRemoteHostKeyStoreError.corruptStore) {
            _ = try MobileRemoteHostKeyStore(databaseURL: url, accountID: "different")
        }
    }

    @Test func timestampsAreInjectedAndRemoveIsDurable() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("host-\(UUID().uuidString).json")
        let profileID = UUID()
        let date = Date(timeIntervalSince1970: 42)
        let challenge = try MobileRemoteSSHHostKeyChallenge(
            profileID: profileID, algorithm: "ssh-ed25519", fingerprint: "SHA256:one"
        )
        let store = try MobileRemoteHostKeyStore(databaseURL: url, accountID: "account", now: { date })
        try await store.record(challenge)
        #expect(await store.observation(for: profileID)?.firstSeenAt == date)
        try await store.remove(profileID: profileID)
        let reopened = try MobileRemoteHostKeyStore(databaseURL: url, accountID: "account")
        #expect(await reopened.observation(for: profileID) == nil)
    }

    @Test func corruptAndForeignFilesFailClosed() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("host-\(UUID().uuidString).json")
        try Data("garbage".utf8).write(to: url)
        #expect(throws: MobileRemoteHostKeyStoreError.corruptStore) {
            _ = try MobileRemoteHostKeyStore(databaseURL: url, accountID: "account")
        }
        #expect(throws: MobileRemoteHostKeyStoreError.invalidAccount) {
            _ = try MobileRemoteHostKeyStore(databaseURL: url.appendingPathExtension("other"), accountID: "")
        }
    }
}
