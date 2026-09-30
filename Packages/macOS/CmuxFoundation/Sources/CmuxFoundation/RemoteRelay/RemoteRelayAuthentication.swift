internal import CryptoKit
public import Foundation

/// Message and MAC construction for the `cmux ssh` CLI relay handshake.
///
/// The relay in the app and the macOS cmux CLI both build their MACs here, so
/// the two sides of the handshake cannot drift. The Go remote CLI
/// (`daemon/remote/cmd/cmuxd-remote/cli.go`) builds the same byte strings.
public enum RemoteRelayAuthentication {
    /// Value of the challenge line's `protocol` field.
    public static let protocolName = "cmux-relay-auth"

    /// The client's MAC over the relay's challenge.
    ///
    /// - Parameters:
    ///   - token: Relay token shared by the relay and its clients.
    ///   - relayID: Relay ID from the challenge.
    ///   - nonce: Relay nonce from the challenge.
    ///   - version: Protocol version from the challenge.
    public static func clientMAC(token: Data, relayID: String, nonce: String, version: Int) -> Data {
        hmac(token: token, message: "relay_id=\(relayID)\nnonce=\(nonce)\nversion=\(version)")
    }

    /// The relay's proof that it holds the token, answering a client nonce.
    ///
    /// The leading label keeps it distinct from every client MAC, whose
    /// message starts with `relay_id=`, so neither can be reflected as the
    /// other.
    ///
    /// - Parameters:
    ///   - token: Relay token shared by the relay and its clients.
    ///   - relayID: Relay ID from the challenge.
    ///   - clientNonce: Hex nonce the client sent with its MAC.
    ///   - serverNonce: Relay nonce from the challenge.
    ///   - version: Protocol version from the challenge.
    public static func relayProofMAC(
        token: Data,
        relayID: String,
        clientNonce: String,
        serverNonce: String,
        version: Int
    ) -> Data {
        hmac(
            token: token,
            message: "cmux-relay-server-proof\nrelay_id=\(relayID)\nclient_nonce=\(clientNonce)\nserver_nonce=\(serverNonce)\nversion=\(version)"
        )
    }

    /// Constant-time equality for secrets and MACs.
    ///
    /// Inputs of different lengths are unequal; the length itself is not
    /// treated as secret.
    public static func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for (left, right) in zip(lhs, rhs) {
            difference |= left ^ right
        }
        return difference == 0
    }

    /// Constant-time equality for UTF-8 strings such as bridge tokens.
    public static func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
        constantTimeEqual(Data(lhs.utf8), Data(rhs.utf8))
    }

    /// Decodes an even-length hex string, or returns `nil`.
    public static func hexData(from string: String) -> Data? {
        let normalized = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, normalized.count.isMultiple(of: 2) else { return nil }
        var data = Data(capacity: normalized.count / 2)
        var cursor = normalized.startIndex
        while cursor < normalized.endIndex {
            let next = normalized.index(cursor, offsetBy: 2)
            guard let byte = UInt8(normalized[cursor..<next], radix: 16) else { return nil }
            data.append(byte)
            cursor = next
        }
        return data
    }

    /// Lowercase hex encoding.
    public static func hexString(from data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    static func hmac(token: Data, message: String) -> Data {
        let key = SymmetricKey(data: token)
        return Data(HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: key))
    }
}
