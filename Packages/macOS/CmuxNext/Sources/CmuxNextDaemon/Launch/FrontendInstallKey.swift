import CryptoKit
public import Foundation

/// The app's install key (P8 slice 3b-2, plans/cmux-next/identity.md):
/// 32 random bytes and an install id, kept by `FrontendInstallKeyStore`.
/// The app hands it to a daemon it starts (`server ensure
/// --install-key-stdin`, never argv or env) and proves itself on each new
/// connection with `client-hello`. The key never appears in a description.
///
/// Its stored form, the install id rule and the hello proof are cmux-daemon-launch-core's
/// (`install_key`, over cmux-local-auth's `frontend_proof`: the bytes the daemon checks). The app
/// keeps only the random source and the stored form.
public struct FrontendInstallKey: Sendable, Hashable, CustomStringConvertible, CustomDebugStringConvertible {
    public let installID: String
    /// `cmuxik1 <install_id> <hex key>\n`.
    private let stored: String

    private struct Answer: Decodable {
        var installId: String
        var payload: String
    }

    private struct Request: Encodable {
        var payload: String?
        var keyHex: String?
        var idRandomHex: String?
        var nonceHex: String?
    }

    private init?(_ answer: Answer?) {
        guard let answer else { return nil }
        installID = answer.installId
        stored = answer.payload
    }

    /// A fresh key and install id (`inst_` + 20 random hex digits), from the system's random bytes. Nil only
    /// when the launch rules do not answer.
    public static func generate() -> FrontendInstallKey? {
        let key = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        let suffix = SymmetricKey(size: .bits128).withUnsafeBytes { Data($0) }
        let request = Request(keyHex: key.hex, idRandomHex: suffix.hex)
        return FrontendInstallKey(DaemonLaunchRules.call("install_key_generate", request, as: Answer?.self) ?? nil)
    }

    /// `cmuxik1 <install_id> <hex key>\n`: the launcher pipe payload, also
    /// the stored form.
    public var payload: Data { Data(stored.utf8) }

    /// Parses `payload`; nil for another tag, an invalid install id, or a key that is not 32 bytes or all zero.
    public init?(payload: Data) {
        guard let text = String(data: payload, encoding: .utf8) else { return nil }
        self.init(DaemonLaunchRules.call("install_key_parse", Request(payload: text), as: Answer?.self) ?? nil)
    }

    /// The `client-hello` step 2 proof for the nonce as the daemon sends it (64 hex digits):
    /// HMAC-SHA256(key, context || 0 || install_id || 0 || nonce), in hex; nil for anything else.
    public func proof(nonceHex: String) -> String? {
        DaemonLaunchRules.call("install_key_proof", Request(payload: stored, nonceHex: nonceHex), as: String?.self) ?? nil
    }

    public var description: String { "FrontendInstallKey(\(installID))" }
    public var debugDescription: String { description }
}

fileprivate extension Data {
    /// Lowercase hex.
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
