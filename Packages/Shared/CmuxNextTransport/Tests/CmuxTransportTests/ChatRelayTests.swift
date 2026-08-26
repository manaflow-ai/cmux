import Foundation
import Testing

@testable import CmuxNextTransport

/// The chat-shaped demo's transport story (Aziz 08-20): two people on
/// different devices, each seeing the OTHER'S keystrokes live before
/// submission, relayed through the host. Typing frames are the terminal
/// input-echo replica; committed messages are the output bursts.
@Suite("Chat fan-out relay")
struct ChatRelayTests {
    @Test("Live drafts and committed messages relay between two admitted peers")
    func twoPeerRelay() async throws {
        let signer = GrantSigner()
        let now: Int64 = 1_000_000
        let host = TransportHost(
            verifier: GrantVerifier(serverPublicKeyData: signer.publicKeyData))

        func admit(_ deviceID: String) async throws -> LoopbackConnectionEnd {
            let identity = PeerIdentity.generate(
                appIdentity: "dev.cmux.lite", deviceID: deviceID)
            let grant = try signer.mint(
                accountID: "a", deviceID: deviceID,
                devicePublicKey: identity.publicKeyData,
                appIdentity: identity.appIdentity, grantID: "g-\(deviceID)", issuedAt: now)
            let (client, hostEnd) = LoopbackWire().makeEnds(
                authenticatedClientKey: identity.publicKeyData)
            async let serving: Void = host.serve(connection: hostEnd, now: now)
            let outcome = try await TransportClient.connect(
                connection: client, identity: identity, grant: grant)
            #expect(outcome != .denied(.revoked))
            await serving
            return client
        }

        let alice = try await admit("phone-alice")
        let bob = try await admit("phone-bob")
        let aliceChat = await alice.lane(TransportHost.chatLaneName)
        let bobChat = await bob.lane(TransportHost.chatLaneName)
        // Give the host's chat services a beat to register both lanes.
        for _ in 0..<50 { await Task.yield() }

        // Alice types character by character; Bob sees every draft state.
        for draft in ["h", "he", "hey"] {
            try await aliceChat.send(Frame.chatTyping(from: "alice", text: draft))
        }
        try await aliceChat.send(Frame.chatMessage(from: "alice", seq: 1, text: "hey"))

        var bobSaw: [String] = []
        for _ in 0..<4 {
            guard let frame = await bobChat.receive() else { break }
            bobSaw.append(
                "\(frame.type):\(frame.payload["text"]?.stringValue ?? "")")
        }
        #expect(bobSaw == [
            "opt.chat.typing:h", "opt.chat.typing:he", "opt.chat.typing:hey",
            "chat.message:hey",
        ])

        // And the other direction.
        try await bobChat.send(Frame.chatTyping(from: "bob", text: "yo"))
        try await bobChat.send(Frame.chatMessage(from: "bob", seq: 1, text: "yo"))
        let first = await aliceChat.receive()
        let second = await aliceChat.receive()
        #expect(first?.type == FrameTypes.chatTyping)
        #expect(second?.type == FrameTypes.chatMessage)
        #expect(second?.payload["from"]?.stringValue == "bob")
    }
}
