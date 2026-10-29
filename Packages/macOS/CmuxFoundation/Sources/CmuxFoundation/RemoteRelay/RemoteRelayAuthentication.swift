internal import CryptoKit
public import Foundation

/// Message and MAC construction for the `cmux ssh` CLI relay handshake.
///
/// The relay in the app and the macOS cmux CLI both build their MACs here, so
/// the two sides of the handshake cannot drift. The Go remote CLI
/// (`daemon/remote/cmd/cmuxd-remote/cli.go`) builds the same byte strings.
public struct RemoteRelayAuthentication: Sendable {
    /// Value of the challenge line's `protocol` field.
    public static let protocolName = "cmux-relay-auth"

    /// Relay token shared by the relay and its clients.
    public let token: Data

    /// Creates the MAC builder for one relay token.
    ///
    /// - Parameter token: Relay token shared by the relay and its clients.
    public init(token: Data) {
        self.token = token
    }

    /// The client's MAC over the relay's challenge.
    ///
    /// - Parameters:
    ///   - relayID: Relay ID from the challenge.
    ///   - nonce: Relay nonce from the challenge.
    ///   - version: Protocol version from the challenge.
    public func clientMAC(relayID: String, nonce: String, version: Int) -> Data {
        hmac("relay_id=\(relayID)\nnonce=\(nonce)\nversion=\(version)")
    }

    /// The relay's proof that it holds the token, answering a client nonce.
    ///
    /// The leading label keeps it distinct from every client MAC, whose
    /// message starts with `relay_id=`, so neither can be reflected as the
    /// other.
    ///
    /// - Parameters:
    ///   - relayID: Relay ID from the challenge.
    ///   - clientNonce: Hex nonce the client sent with its MAC.
    ///   - serverNonce: Relay nonce from the challenge.
    ///   - version: Protocol version from the challenge.
    public func relayProofMAC(
        relayID: String,
        clientNonce: String,
        serverNonce: String,
        version: Int
    ) -> Data {
        hmac(
            "cmux-relay-server-proof\nrelay_id=\(relayID)\nclient_nonce=\(clientNonce)\nserver_nonce=\(serverNonce)\nversion=\(version)"
        )
    }

    private func hmac(_ message: String) -> Data {
        let key = SymmetricKey(data: token)
        return Data(HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: key))
    }
}

extension Data {
    /// Decodes an even-length hex string such as a relay token or MAC.
    ///
    /// - Parameter relayHex: Hex text; surrounding whitespace is ignored.
    /// - Returns: `nil` for empty, odd-length or non-hex text.
    public init?(relayHex: String) {
        let normalized = relayHex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, normalized.count.isMultiple(of: 2) else { return nil }
        var data = Data(capacity: normalized.count / 2)
        var cursor = normalized.startIndex
        while cursor < normalized.endIndex {
            let next = normalized.index(cursor, offsetBy: 2)
            guard let byte = UInt8(normalized[cursor..<next], radix: 16) else { return nil }
            data.append(byte)
            cursor = next
        }
        self = data
    }

    /// Lowercase hex encoding, as the relay handshake sends MACs and nonces.
    public var relayHexString: String {
        map { String(format: "%02x", $0) }.joined()
    }

    /// Constant-time equality for secrets and MACs.
    ///
    /// Inputs of different lengths are unequal; the length itself is not
    /// treated as secret.
    ///
    /// - Parameter other: The value to compare with.
    public func constantTimeEquals(_ other: Data) -> Bool {
        guard count == other.count else { return false }
        var difference: UInt8 = 0
        for (left, right) in zip(self, other) {
            difference |= left ^ right
        }
        return difference == 0
    }
}

extension String {
    /// Constant-time equality of the UTF-8 bytes, for tokens such as the
    /// PTY bridge token.
    ///
    /// - Parameter other: The string to compare with.
    public func constantTimeEquals(_ other: String) -> Bool {
        Data(utf8).constantTimeEquals(Data(other.utf8))
    }
}
