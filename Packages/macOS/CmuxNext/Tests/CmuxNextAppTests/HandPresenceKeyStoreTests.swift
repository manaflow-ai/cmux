@testable import CmuxNextCloud
import CmuxNextCompat
import CmuxNextWakeups
import CryptoKit
import Foundation
import Testing

/// p15-oracle-141: the presence key's maker is injected (`UserPresence`), and the install store picks the Secure
/// Enclave on macOS exactly as before.
@Suite struct HandPresenceKeyStoreTests {
    /// A software presence key that records what it signed.
    final class SoftwarePresence: UserPresence {
        let key = P256.Signing.PrivateKey()
        private let log = Mutex<[Signed]>([])
        var signed: [Signed] { log.withLock { $0 } }
        var isAvailable: Bool { true }

        struct Signed: Equatable {
            var message: String, blob: Data, reason: String
        }

        func makeKey() throws(HandPresenceError) -> (blob: Data, publicKeyX963: Data) {
            (key.rawRepresentation, key.publicKey.x963Representation)
        }

        func sign(_ message: String, blob: Data, prompt: HandPresencePrompt) async throws(HandPresenceError) -> String {
            let entry = Signed(message: message, blob: blob, reason: prompt.reason)
            log.withLock { $0.append(entry) }
            return "signed:\(message)"
        }
    }

    static func directory() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "hand-presence-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    @Test func aDeviceWithoutPresenceRefusesTheKeyAndWritesNothing() throws {
        let root = Self.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = HandPresenceKeyStore(directory: root, presence: NoUserPresence())

        #expect(!store.isAvailable)
        #expect(throws: HandPresenceError.unavailable) { try store.recordOrCreate(for: "user-1") }
        #expect(store.record(for: "user-1") == nil)
    }

    @Test func theInjectedPresenceMakesTheKeyOnceAndSignsWithItsBlob() async throws {
        let root = Self.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let presence = SoftwarePresence()
        let store = HandPresenceKeyStore(directory: root, presence: presence)

        #expect(store.isAvailable)
        let made = try store.recordOrCreate(for: "user-1")
        let again = try store.recordOrCreate(for: "user-1")
        let point = presence.key.publicKey.x963Representation
        #expect(again == made)
        #expect(made.blob == presence.key.rawRepresentation)
        #expect(made.x == point.subdata(in: 1..<33).base64URLEncodedForTest)
        #expect(made.y == point.subdata(in: 33..<65).base64URLEncodedForTest)
        #expect(made.install == nil)

        let signature = try await store.sign("proof", record: made, prompt: HandPresencePrompt(reason: "raise the hand h to full"))
        #expect(signature == "signed:proof")
        #expect(presence.signed == [SoftwarePresence.Signed(message: "proof", blob: made.blob, reason: "raise the hand h to full")])
    }

    /// macOS keeps its install keys where they were: files only for a debug build with no Team ID.
    @Test func theInstallStoreUsesTheEnclaveUnlessADebugBuildHasNoTeam() {
        let root = Self.directory()
        let work = BackgroundWork(label: "test.install-store")
        func enclave(team: String?, debug: Bool) -> Bool {
            MacInstallStore.forApp(directory: root, service: "s", team: team, isDebugBuild: debug, work: work).usesSecureEnclave
        }
        #expect(!enclave(team: nil, debug: true))
        #expect(enclave(team: "TEAMID", debug: true))
        #expect(enclave(team: nil, debug: false))
        #expect(enclave(team: "TEAMID", debug: false))
    }
}

private extension Data {
    /// RFC 4648 base64url without padding, as a JWK coordinate.
    var base64URLEncodedForTest: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
