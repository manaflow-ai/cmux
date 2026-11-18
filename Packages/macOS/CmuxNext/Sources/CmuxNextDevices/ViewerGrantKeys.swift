public import CmuxNextCompat
import CryptoKit
public import Foundation
import LocalAuthentication
import Security

/// A viewer's Touch ID grant for a host that asks for consent (CMUX-572; the rules and the host's
/// checks are Rust, `cmux-tui/crates/acpmux/src/viewer_grant.rs`). This is only the glue: one Secure
/// Enclave key per host and scope whose every use needs Touch ID or the login password, its public
/// half for the host to register, and its signature over the host's challenge. The private key never
/// leaves the enclave; the keychain keeps only the enclave's encrypted blob, this device only.
public enum ViewerGrantScope: String, Sendable, CaseIterable {
    case view, control
}

/// What the viewer signs for one session: `Proof::canonical` in Rust, held to the same bytes by
/// `viewer_grant_vectors.json`.
public struct ViewerGrantProof: Equatable, Sendable {
    public static let version = "cmux.viewer-proof.v1"

    public var host: String
    public var viewer: String
    public var scope: ViewerGrantScope
    public var session: String
    public var challenge: String
    public var signature = ""

    public init(host: String, viewer: String, scope: ViewerGrantScope, session: String, challenge: String) {
        self.host = host
        self.viewer = viewer
        self.scope = scope
        self.session = session
        self.challenge = challenge
    }

    public var canonical: String {
        "\(Self.version)\nhost=\(host)\nviewer=\(viewer)\nscope=\(scope.rawValue)\nsession=\(session)\nchallenge=\(challenge)"
    }

    /// The proof with `sign`'s raw r||s signature of ``canonical``, base64.
    public func signed(with sign: (Data) throws -> Data) rethrows -> ViewerGrantProof {
        var copy = self
        copy.signature = try sign(Data(canonical.utf8)).base64EncodedString()
        return copy
    }

    /// The `proof` object the host reads (`Proof` in Rust).
    public var json: [String: String] {
        ["v": Self.version, "host": host, "viewer": viewer, "scope": scope.rawValue, "session": session,
         "challenge": challenge, "signature": signature]
    }
}

/// The viewer's grant keys in this build's keychain (`<bundle id>.viewer-grant`), one per host and scope.
public struct ViewerGrantKeys: Sendable {
    public enum Failure: Error, Equatable, Sendable {
        case noKey
        case enclave(String)
    }

    let keychain: DeviceKeychain

    public init(bundleIdentifier: String, loginKeychain: LoginKeychain) {
        keychain = DeviceKeychain(service: bundleIdentifier + ".viewer-grant", loginKeychain: loginKeychain)
    }

    static func account(host: String, scope: ViewerGrantScope) -> String { "\(host)\n\(scope.rawValue)" }

    /// Makes the key for `host` and `scope` (replacing an earlier one) and returns its public half,
    /// base64 X9.63, for the host to register. Making it asks nothing; each signature asks.
    public func make(host: String, scope: ViewerGrantScope) throws -> String {
        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                                                           [.privateKeyUsage, .userPresence], &error) else {
            throw Failure.enclave("access control: \(error?.takeRetainedValue().localizedDescription ?? "unknown")")
        }
        let key: SecureEnclave.P256.Signing.PrivateKey
        do { key = try SecureEnclave.P256.Signing.PrivateKey(accessControl: access) } catch { throw Failure.enclave("\(error)") }
        try keychain.write(key.dataRepresentation, account: Self.account(host: host, scope: scope))
        return key.publicKey.x963Representation.base64EncodedString()
    }

    /// Signs `proof` with the key for its host and scope. Touch ID (or the login password) asks, with
    /// `reason` after the app's name; the enclave's wait runs off the main thread.
    public func sign(_ proof: ViewerGrantProof, reason: String) async throws -> ViewerGrantProof {
        guard let blob = try keychain.read(Self.account(host: proof.host, scope: proof.scope)) else { throw Failure.noKey }
        return try await Task.detached(priority: .userInitiated) {
            let context = LAContext()
            context.localizedReason = reason
            do {
                let key = try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: blob, authenticationContext: context)
                return try proof.signed { try key.signature(for: $0).rawRepresentation }
            } catch { throw Failure.enclave("\(error)") }
        }.value
    }

    /// Forgets the key for `host` and `scope` (the host's copy of the public half is revoked there).
    public func delete(host: String, scope: ViewerGrantScope) {
        _ = keychain.deleteStatus(Self.account(host: host, scope: scope))
    }
}
