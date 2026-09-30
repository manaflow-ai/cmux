public import Foundation

/// The client side of the `cmux ssh` CLI relay handshake.
///
/// The macOS cmux CLI runs it on a remote Mac, where `CMUX_SOCKET_PATH` names
/// a forwarded TCP port on the remote loopback. The caller owns the socket and
/// its deadlines and passes line I/O in; nothing but the handshake is written
/// until ``perform(readLine:writeLine:)`` returns.
public struct RemoteRelayClientHandshake: Sendable {
    /// Why the handshake refused to continue.
    public enum Failure: Error, Equatable, Sendable {
        /// The first line is not a challenge for this relay ID.
        case invalidChallenge
        /// The relay rejected the client's MAC.
        case rejected
    }

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

        let mac = RemoteRelayAuthentication.clientMAC(
            token: relayToken,
            relayID: relayID,
            nonce: nonce,
            version: version
        )
        let payload = try JSONSerialization.data(withJSONObject: [
            "relay_id": relayID,
            "mac": RemoteRelayAuthentication.hexString(from: mac),
        ])
        try writeLine(payload + Data([0x0A]))

        guard let result = Self.jsonObject(try readLine()),
              (result["ok"] as? Bool) == true else {
            throw Failure.rejected
        }
    }

    private static func jsonObject(_ line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
