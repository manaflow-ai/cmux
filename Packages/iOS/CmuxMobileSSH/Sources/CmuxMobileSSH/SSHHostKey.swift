import Crypto
import Foundation
import NIOSSH

/// A server identity key as presented during the handshake.
public struct SSHHostKey: Hashable, Sendable, Codable {
    /// OpenSSH public key line without a comment, e.g. `ssh-ed25519 AAAA...`.
    public var openSSHString: String

    public init(openSSHString: String) {
        self.openSSHString = openSSHString
    }

    init(_ key: NIOSSHPublicKey) {
        self.openSSHString = String(openSSHPublicKey: key)
    }

    /// Key algorithm name, e.g. `ssh-ed25519`.
    public var algorithm: String {
        openSSHString.split(separator: " ").first.map(String.init) ?? ""
    }

    /// OpenSSH-format fingerprint, `SHA256:<base64 without padding>`, matching `ssh-keygen -lf`.
    public var sha256Fingerprint: String {
        let parts = openSSHString.split(separator: " ")
        guard parts.count >= 2, let blob = Data(base64Encoded: String(parts[1])) else {
            return "SHA256:?"
        }
        let digest = Data(SHA256.hash(data: blob)).base64EncodedString()
        return "SHA256:" + digest.replacingOccurrences(of: "=", with: "")
    }
}

/// What the host key policy concluded about a presented key.
public enum SSHHostKeyVerdict: Hashable, Sendable {
    /// Matches the pinned key.
    case trusted
    /// First connection to this host; nothing pinned yet.
    case unknown(presented: SSHHostKey)
    /// A different key is pinned. Either a reinstall or an impersonation (PRD D17).
    case changed(pinned: SSHHostKey, presented: SSHHostKey)
}

/// Decides whether a presented host key may be used. Implementations own the
/// trust-on-first-use prompt and the stop-and-ask flow for changed keys.
public protocol SSHHostKeyVerifier: Sendable {
    /// Returns `true` to continue the handshake.
    func verify(_ key: SSHHostKey, for endpoint: SSHEndpoint) async -> Bool
}

/// Pinned host keys keyed by ``SSHEndpoint/hostKeyIdentity``.
public protocol SSHKnownHostsStore: Sendable {
    func pinnedKey(for identity: String) async -> SSHHostKey?
    func pin(_ key: SSHHostKey, for identity: String) async
}

extension SSHHostKeyVerdict {
    /// The verdict on a presented key given the key pinned for the host, if
    /// any. Pure, and shared by every verifier.
    ///
    /// - Parameters:
    ///   - presented: The key the server presented.
    ///   - pinned: The key previously trusted for this host, `nil` when none.
    public init(presented: SSHHostKey, pinned: SSHHostKey?) {
        guard let pinned else {
            self = .unknown(presented: presented)
            return
        }
        self = pinned == presented ? .trusted : .changed(pinned: pinned, presented: presented)
    }
}
