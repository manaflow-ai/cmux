public import Foundation
internal import Security

/// The client side of the `cmux ssh` CLI relay handshake.
///
/// The macOS cmux CLI runs it on a remote Mac, where `CMUX_SOCKET_PATH` names
/// a forwarded TCP port on the remote loopback. While that forward is down,
/// another user on the remote Mac can bind the port, so the handshake is
/// mutual: the client proves the token with its MAC over the relay's nonce,
/// and the relay proves it with `relay_mac` over a fresh client nonce. The
/// caller owns the socket and its deadlines and passes line I/O in; nothing
/// but the auth line is written until ``perform(readLine:writeLine:)``
/// returns, and it returns only after the relay's proof checks out.
public struct RemoteRelayClientHandshake: Sendable {
    /// Why the handshake refused to continue.
    public enum Failure: Error, Equatable, Sendable {
        /// The first line is not a challenge for this relay ID.
        case invalidChallenge
        /// The relay rejected the client's MAC.
        case rejected
        /// The listener did not prove it holds the relay token.
        case relayNotProven
        /// No random client nonce could be generated.
        case nonceUnavailable
    }

    /// Size of the client nonce, matching the Go remote CLI.
    public static let clientNonceByteCount = 32

    private let relayID: String
    private let relayToken: Data

    /// Creates a handshake for one relay.
    ///
    /// - Parameters:
    ///   - relayID: Relay ID from the relay's credentials.
    ///   - relayToken: Relay token from the relay's credentials.
    public init(relayID: String, relayToken: Data) {
        self.relayID = relayID
        self.relayToken = relayToken
    }

    /// Runs the handshake.
    ///
    /// - Parameters:
    ///   - readLine: Returns the next line from the relay, without its newline.
    ///   - writeLine: Writes one line to the relay; the data ends with a newline.
    /// - Throws: ``Failure`` when the relay is not authenticated, or any error
    ///   from `readLine` and `writeLine`.
    public func perform(
        readLine: () throws -> String,
        writeLine: (Data) throws -> Void
    ) throws {
        let challengeLine = try readLine()
        guard let challenge = Self.jsonObject(challengeLine),
              (challenge["protocol"] as? String) == RemoteRelayAuthentication.protocolName,
              let version = challenge["version"] as? Int,
              let challengeRelayID = challenge["relay_id"] as? String,
              challengeRelayID == relayID,
              let nonce = challenge["nonce"] as? String,
              !nonce.isEmpty else {
            throw Failure.invalidChallenge
        }
        guard !relayToken.isEmpty else { throw Failure.rejected }
        guard let clientNonce = Self.randomClientNonce() else {
            throw Failure.nonceUnavailable
        }

        let authentication = RemoteRelayAuthentication(token: relayToken)
        let mac = authentication.clientMAC(
            relayID: relayID,
            nonce: nonce,
            version: version
        )
        let payload = try JSONSerialization.data(withJSONObject: [
            "relay_id": relayID,
            "mac": mac.relayHexString,
            "client_nonce": clientNonce,
        ])
        try writeLine(payload + Data([0x0A]))

        guard let result = Self.jsonObject(try readLine()),
              (result["ok"] as? Bool) == true else {
            throw Failure.rejected
        }
        // Anyone who connected once has seen the relay ID, so only a proof
        // over this client's nonce shows the listener holds the relay token.
        let expectedProof = authentication.relayProofMAC(
            relayID: relayID,
            clientNonce: clientNonce,
            serverNonce: nonce,
            version: version
        )
        guard let proofHex = result["relay_mac"] as? String,
              let receivedProof = Data(relayHex: proofHex),
              receivedProof.constantTimeEquals(expectedProof) else {
            throw Failure.relayNotProven
        }
    }

    private static func randomClientNonce() -> String? {
        var bytes = [UInt8](repeating: 0, count: clientNonceByteCount)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            return nil
        }
        return Data(bytes).relayHexString
    }

    private static func jsonObject(_ line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
