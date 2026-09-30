import CryptoKit
import Foundation
import Testing

@testable import CmuxFoundation

/// A relay listener driven by the client's line I/O. It answers the auth line
/// with `result(authLine)` and records everything the client writes.
private final class FakeRelay {
    let relayID: String
    let serverNonce = "0123456789abcdef0123456789abcdef"
    private let result: ([String: Any]) -> String
    private var pendingLines: [String]
    private(set) var receivedLines: [String] = []

    init(relayID: String, result: @escaping ([String: Any]) -> String) {
        self.relayID = relayID
        self.result = result
        pendingLines = [
            #"{"protocol":"cmux-relay-auth","version":1,"relay_id":"\#(relayID)","nonce":"\#(serverNonce)"}"#,
        ]
    }

    func readLine() throws -> String {
        guard !pendingLines.isEmpty else { throw POSIXError(.ECONNRESET) }
        return pendingLines.removeFirst()
    }

    func writeLine(_ data: Data) throws {
        let line = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .newlines)
        receivedLines.append(line)
        if receivedLines.count == 1 {
            let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] ?? [:]
            pendingLines.append(result(object))
        }
    }
}

@Suite
struct RemoteRelayConstantTimeEqualTests {
    @Test(arguments: [
        ("token-abc", "token-abc", true),
        ("token-abc", "token-abd", false),
        ("token-abc", "token-ab", false),
        ("token-abc", "token-abcd", false),
        ("", "", true),
        ("", "x", false),
    ])
    func comparesStrings(lhs: String, rhs: String, expected: Bool) {
        #expect(RemoteRelayAuthentication.constantTimeEqual(lhs, rhs) == expected)
        #expect(RemoteRelayAuthentication.constantTimeEqual(Data(lhs.utf8), Data(rhs.utf8)) == expected)
    }
}

@Suite
struct RemoteRelayClientHandshakeTests {
    private static let relayID = "relay-handshake-test"
    private static let token = Data((0..<32).map { UInt8($0) })
    private static let request = #"{"id":"1","method":"notification.create","params":{"title":"secret"}}"#

    /// Independent oracle for the relay's proof, built from the wire format
    /// rather than the shared helper.
    private static func proofHex(clientNonce: String, serverNonce: String, token: Data = token) -> String {
        let message = "cmux-relay-server-proof\nrelay_id=\(relayID)\nclient_nonce=\(clientNonce)\nserver_nonce=\(serverNonce)\nversion=1"
        let mac = HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: SymmetricKey(data: token))
        return Data(mac).map { String(format: "%02x", $0) }.joined()
    }

    /// Mirrors the CLI: authenticate, then send the command on the same connection.
    private static func sendCommand(through relay: FakeRelay) throws {
        let handshake = RemoteRelayClientHandshake(relayID: relayID, relayToken: token)
        try handshake.perform(readLine: relay.readLine, writeLine: relay.writeLine)
        try relay.writeLine(Data((request + "\n").utf8))
    }

    @Test("a listener that answers ok without relay_mac never receives the command")
    func okWithoutRelayProofIsRefused() {
        let relay = FakeRelay(relayID: Self.relayID) { _ in #"{"ok":true}"# }

        #expect(throws: (any Error).self) { try Self.sendCommand(through: relay) }
        #expect(relay.receivedLines.count == 1, "Only the auth line may reach an unproven relay")
        #expect(!relay.receivedLines.contains { $0.contains("notification.create") })
    }

    @Test("a relay_mac made with another token is refused")
    func proofWithWrongTokenIsRefused() {
        let relay = FakeRelay(relayID: Self.relayID) { auth in
            let clientNonce = auth["client_nonce"] as? String ?? ""
            let proof = Self.proofHex(
                clientNonce: clientNonce,
                serverNonce: "0123456789abcdef0123456789abcdef",
                token: Data(repeating: 0xEE, count: 32)
            )
            return #"{"ok":true,"relay_mac":"\#(proof)"}"#
        }

        #expect(throws: (any Error).self) { try Self.sendCommand(through: relay) }
        #expect(!relay.receivedLines.contains { $0.contains("notification.create") })
    }

    @Test("a relay_mac replayed from another client nonce is refused")
    func replayedProofIsRefused() {
        let relay = FakeRelay(relayID: Self.relayID) { _ in
            let replayed = Self.proofHex(
                clientNonce: String(repeating: "ab", count: 32),
                serverNonce: "0123456789abcdef0123456789abcdef"
            )
            return #"{"ok":true,"relay_mac":"\#(replayed)"}"#
        }

        #expect(throws: (any Error).self) { try Self.sendCommand(through: relay) }
        #expect(!relay.receivedLines.contains { $0.contains("notification.create") })
    }

    @Test("each auth line carries a fresh 32-byte client nonce")
    func authLineCarriesFreshClientNonce() throws {
        var nonces: [String] = []
        for _ in 0..<2 {
            let relay = FakeRelay(relayID: Self.relayID) { _ in #"{"ok":false}"# }
            _ = try? Self.sendCommand(through: relay)
            let authLine = try #require(relay.receivedLines.first)
            let auth = try #require(
                JSONSerialization.jsonObject(with: Data(authLine.utf8)) as? [String: Any]
            )
            let nonce = try #require(auth["client_nonce"] as? String)
            #expect(nonce.count == 64)
            #expect(nonce.allSatisfy { $0.isHexDigit && !$0.isUppercase })
            nonces.append(nonce)
        }
        #expect(nonces[0] != nonces[1])
    }

    @Test("a relay that proves the token receives the command")
    func provenRelayReceivesCommand() throws {
        let relay = FakeRelay(relayID: Self.relayID) { auth in
            guard let clientNonce = auth["client_nonce"] as? String else { return #"{"ok":true}"# }
            let proof = Self.proofHex(
                clientNonce: clientNonce,
                serverNonce: "0123456789abcdef0123456789abcdef"
            )
            return #"{"ok":true,"relay_mac":"\#(proof)"}"#
        }

        try Self.sendCommand(through: relay)
        #expect(relay.receivedLines.last == Self.request)
    }
}
