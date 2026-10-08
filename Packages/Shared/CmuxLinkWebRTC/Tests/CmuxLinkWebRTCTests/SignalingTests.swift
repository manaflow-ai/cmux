import CmuxLink
import CmuxLinkSignaling
@_spi(Testing) import CmuxLinkWebRTC
import CmuxMobileWire
import Foundation
import Testing

@Suite("Signaling")
struct SignalingTests {
    let codec = SignalFrameCodec()

    /// The A0 fixtures (schemas/mobile-rpc/fixtures/signal.json) decode into
    /// typed messages and encode back to the same frame.
    @Test("A0 signal fixtures round trip")
    func fixtures() throws {
        let url = repositoryRoot.appendingPathComponent("schemas/mobile-rpc/fixtures/signal.json")
        let root = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let cases = try #require(root["cases"] as? [[String: Any]])
        var decoded = 0
        for entry in cases {
            let frame = try #require(entry["frame"] as? [String: Any])
            guard frame["t"] as? String == "signal" else { continue }
            let signal = try JSONDecoder().decode(SignalFrame.self, from: JSONSerialization.data(withJSONObject: frame))
            let message = try #require(codec.message(from: signal), "\(entry["message"] ?? "")")
            #expect(codec.frame(for: message) == signal)
            decoded += 1
        }
        #expect(decoded == 5)
    }

    @Test("auth rides offer and answer bodies as base64")
    func authRoundTrip() throws {
        let auth = SignalAuth(key: Data(repeating: 4, count: 65), signature: Data(repeating: 9, count: 64))
        for payload in [SignalPayload.offer(sdp: "v=0", iceRestart: true, carrier: .webrtc, auth: auth), .answer(sdp: "v=0", auth: auth)] {
            let message = SignalMessage(session: "sess_Ab12", to: "h_mac1A2b", payload: payload)
            let frame = codec.frame(for: message)
            guard case let .object(fields)? = frame.body["auth"] else {
                Issue.record("no auth object")
                continue
            }
            #expect(fields["key"] == .string(auth.key.base64EncodedString()))
            #expect(codec.message(from: frame) == message)
        }
    }

    @Test("offers name their carrier; unknown carriers and bad bodies are ignored")
    func carriers() {
        let wg = SignalFrame(kind: .offer, session: "sess_Ab12", to: "h", body: ["sdp": .string("v=0"), "carrier": .string("webrtc-wg")])
        guard case let .offer(_, _, carrier, _)? = codec.message(from: wg)?.payload else {
            Issue.record("wg offer did not decode")
            return
        }
        #expect(carrier == .webrtcWireGuard)
        let legacy = SignalFrame(kind: .offer, session: "sess_Ab12", to: "h", body: ["sdp": .string("v=0")])
        if case let .offer(_, _, carrier, _)? = codec.message(from: legacy)?.payload { #expect(carrier == .webrtc) }
        let sfu = SignalFrame(kind: .offer, session: "sess_Ab12", to: "h", body: ["sdp": .string("v=0"), "carrier": .string("sfu")])
        #expect(codec.message(from: sfu) == nil)
        let bye = SignalFrame(kind: .bye, session: "sess_Ab12", to: "h", body: ["reason": .string("bored")])
        #expect(codec.message(from: bye) == nil)
    }

    @Test("session ids match the relay's pattern")
    func sessionIDs() throws {
        let regex = try Regex("^sess_[A-Za-z0-9]{2,64}$")
        let ids = (0..<64).map { _ in SignalSessionID().rawValue }
        #expect(ids.allSatisfy { $0.wholeMatch(of: regex) != nil })
        #expect(Set(ids).count == ids.count)
    }

    @Test("the in-memory relay rewrites from and refuses offline peers")
    func hubRewritesFrom() async throws {
        let hub = InMemorySignalingHub()
        let phone = hub.endpoint(id: "in_phone")
        let mac = hub.endpoint(id: "h_mac")
        try await phone.send(SignalMessage(session: "sess_a1", to: "h_mac", from: "h_forged", payload: .iceEnd))
        var iterator = mac.incoming.makeAsyncIterator()
        let received = await iterator.next()
        #expect(received?.from == "in_phone")
        await #expect(throws: InMemorySignalingError.peerOffline("h_gone")) {
            try await phone.send(SignalMessage(session: "sess_a1", to: "h_gone", payload: .iceEnd))
        }
    }

    @Test("the router demultiplexes by session and opens inboxes for new offers")
    func router() async throws {
        let hub = InMemorySignalingHub()
        let phone = hub.endpoint(id: "in_phone")
        let router = SignalRouter(channel: hub.endpoint(id: "h_mac"))
        let mine = await router.register("sess_mine")
        let newSessions = await router.newSessions(for: .webrtc)
        let wgSessions = await router.newSessions(for: .webrtcWireGuard)
        let offer = SignalMessage(session: "sess_new", to: "h_mac", payload: .offer(sdp: "v=0", iceRestart: false, carrier: .webrtc, auth: nil))
        let candidate = SignalMessage(session: "sess_new", to: "h_mac", payload: .ice(ICECandidateInit(candidate: "candidate:1", sdpMid: "0", sdpMLineIndex: 0)))
        // Unknown session without an offer: dropped, never queued.
        try await phone.send(SignalMessage(session: "sess_stray", to: "h_mac", payload: .iceEnd))
        try await phone.send(SignalMessage(session: "sess_mine", to: "h_mac", payload: .iceEnd))
        try await phone.send(offer)
        try await phone.send(candidate)
        let wgOffer = SignalMessage(session: "sess_wg", to: "h_mac", payload: .offer(sdp: "v=0", iceRestart: false, carrier: .webrtcWireGuard, auth: nil))
        try await phone.send(wgOffer)

        var mineIterator = mine.makeAsyncIterator()
        #expect(await mineIterator.next()?.payload == .iceEnd)
        var sessions = newSessions.makeAsyncIterator()
        let incoming = try #require(await sessions.next())
        #expect(incoming.session == "sess_new")
        var inbox = incoming.inbox.makeAsyncIterator()
        #expect(await inbox.next()?.payload == offer.payload)
        #expect(await inbox.next()?.payload == candidate.payload)
        var wgIterator = wgSessions.makeAsyncIterator()
        #expect(await wgIterator.next()?.session == "sess_wg")
        #expect(await router.liveSessions == 3)
        await router.unregister("sess_new")
        #expect(await router.liveSessions == 2)
    }

    @Test("the router bounds session inboxes and pending offers")
    func routerBounds() async throws {
        let hub = InMemorySignalingHub()
        let phone = hub.endpoint(id: "in_phone")
        let router = SignalRouter(channel: hub.endpoint(id: "h_mac"))
        let mine = await router.register("sess_mine")
        let probe = await router.register("sess_probe")
        let unread = await router.newSessions(for: .webrtc)
        let candidate = SignalPayload.ice(ICECandidateInit(candidate: "candidate:1", sdpMid: "0", sdpMLineIndex: 0))
        // A session whose reader stalls is ended, not queued without bound.
        for _ in 0...SignalRouter.inboxLimit {
            try await phone.send(SignalMessage(session: "sess_mine", to: "h_mac", payload: candidate))
        }
        // Offers nobody takes past the acceptor's limit are refused.
        for index in 0...SignalRouter.pendingSessionLimit {
            try await phone.send(SignalMessage(session: "sess_new\(index)", to: "h_mac",
                                               payload: .offer(sdp: "v=0", iceRestart: false, carrier: .webrtc, auth: nil)))
        }
        try await phone.send(SignalMessage(session: "sess_probe", to: "h_mac", payload: .iceEnd))
        var probeIterator = probe.makeAsyncIterator()
        #expect(await probeIterator.next()?.payload == .iceEnd)
        // Left: the probe and the accepted offers (the stalled session ended).
        let live = await router.liveSessions
        #expect(live == SignalRouter.pendingSessionLimit + 1)
        guard live == SignalRouter.pendingSessionLimit + 1 else { return }
        var queued = 0
        for await _ in mine { queued += 1 }
        #expect(queued == SignalRouter.inboxLimit)
        withExtendedLifetime(unread) {}
    }

    @Test("stopping the router permanently finishes new sessions")
    func routerStopIsTerminal() async throws {
        let router = SignalRouter(channel: InMemorySignalingHub().endpoint(id: "h_mac"))
        let before = await router.register("sess_before")
        await router.stop()
        #expect(await router.liveSessions == 0)
        let after = await router.register("sess_after")
        let sessions = await router.newSessions(for: .webrtc)
        var beforeIterator = before.makeAsyncIterator()
        var afterIterator = after.makeAsyncIterator()
        var sessionIterator = sessions.makeAsyncIterator()
        #expect(await beforeIterator.next() == nil)
        #expect(await afterIterator.next() == nil)
        #expect(await sessionIterator.next() == nil)
    }

    @Test("the raw-frame channel decodes relayed frames and never sends from")
    func frameChannel() async throws {
        let sent = SentFrames()
        let channel = SignalFrameChannel { await sent.append($0) }
        await channel.receive(SignalFrame(kind: .iceEnd, session: "sess_a1", to: "h_mac", from: "in_phone", body: [:]))
        var iterator = channel.incoming.makeAsyncIterator()
        #expect(await iterator.next()?.from == "in_phone")
        try await channel.send(SignalMessage(session: "sess_a1", to: "in_phone", from: "h_forged", payload: .bye(.closed)))
        let frames = await sent.frames
        #expect(frames.count == 1)
        #expect(frames.first?.from == nil)
        #expect(frames.first?.kind == .bye)
    }
}

actor SentFrames {
    private(set) var frames: [SignalFrame] = []
    func append(_ frame: SignalFrame) { frames.append(frame) }
}
