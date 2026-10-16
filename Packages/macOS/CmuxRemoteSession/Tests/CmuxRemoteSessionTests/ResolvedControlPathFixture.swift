import CmuxFoundation
import Foundation

enum ResolvedControlPathFixture {
    /// A resolved socket in the private directory cmux uses on this machine.
    static let path =
        (SSHConnectionSharingOptions().controlSocketDirectoryPath ?? "/unavailable-cmux-ssh") +
        "/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

    /// A unique endpoint identity for tests that run concurrently under Swift Testing.
    ///
    /// The relay tests exercise process and ownership coordination, so reusing one
    /// relay id, persistent slot, and resolved ControlPath lets unrelated fixtures
    /// observe one another's state. Keep the path in cmux's private socket directory
    /// so it still exercises the production ownership predicate.
    static func uniqueIdentity() -> Identity {
        let suffix = (
            UUID().uuidString + UUID().uuidString
        ).replacingOccurrences(of: "-", with: "").lowercased()
        let socketDirectory =
            SSHConnectionSharingOptions().controlSocketDirectoryPath ??
            "/unavailable-cmux-ssh"
        let relayPort =
            64_044 + (Int(String(suffix.prefix(4)), radix: 16)! % 1_000)
        return Identity(
            relayID: "relay-test-\(suffix)",
            persistentDaemonSlot: "slot-test-\(suffix)",
            relayPort: relayPort,
            controlPath: socketDirectory + "/\(suffix.prefix(40))"
        )
    }

    struct Identity: Sendable {
        let relayID: String
        let persistentDaemonSlot: String
        let relayPort: Int
        let controlPath: String
    }
}
