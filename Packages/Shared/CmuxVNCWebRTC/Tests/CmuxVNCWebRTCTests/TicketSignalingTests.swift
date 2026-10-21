import CoreVideo
import CryptoKit
@testable import CmuxVNCWebRTC
import Foundation
import Testing

/// A software signing key standing in for the device's Secure Enclave key.
struct SoftwareTicketSigner: ScreenTicketSigner {
    let key = P256.Signing.PrivateKey()
    var publicKey: String { key.publicKey.x963Representation.base64EncodedString() }

    func deviceHeaders(for url: URL) async throws -> [String: String] {
        ["X-Device-Id": "device-1", "X-Device-Ts": "1800000000", "X-Device-Sig": "sig-of-\(url.path)"]
    }

    func sign(_ message: Data) async throws -> Data { try key.signature(for: message).rawRepresentation }
}

/// The Session DO's other end: frames to deliver, frames this side sent.
final class FakeSignalSocket: ScreenSignalSocket, @unchecked Sendable {
    private let lock = NSLock()
    private var inbox: [String] = []
    private var waiter: CheckedContinuation<String, any Error>?
    private var sentFrames: [String] = []
    private var isClosed = false

    var sent: [String] { lock.withLock { sentFrames } }
    var closed: Bool { lock.withLock { isClosed } }

    func deliver(_ text: String) {
        let waiter = lock.withLock { () -> CheckedContinuation<String, any Error>? in
            defer { self.waiter = nil }
            if self.waiter == nil { inbox.append(text) }
            return self.waiter
        }
        waiter?.resume(returning: text)
    }

    func receive() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let ready = lock.withLock { () -> Result<String, any Error>? in
                if isClosed { return .failure(URLError(.networkConnectionLost)) }
                if !inbox.isEmpty { return .success(inbox.removeFirst()) }
                waiter = continuation
                return nil
            }
            if let ready { continuation.resume(with: ready) }
        }
    }

    func send(_ text: String) async throws { lock.withLock { sentFrames.append(text) } }

    func close() {
        let waiter = lock.withLock { () -> CheckedContinuation<String, any Error>? in
            isClosed = true
            defer { self.waiter = nil }
            return self.waiter
        }
        waiter?.resume(throwing: URLError(.networkConnectionLost))
    }
}

final class RequestBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: URLRequest?
    var value: URLRequest? { lock.withLock { stored } }
    func set(_ request: URLRequest) { lock.withLock { stored = request } }
}

struct TicketSignalingTests {
    static let sdp = """
    v=0\r
    o=- 1 2 IN IP4 127.0.0.1\r
    a=fingerprint:sha-256 AA:BB:CC\r
    m=video 9 UDP/TLS/RTP/SAVPF 96\r
    a=fingerprint:sha-256 DD:EE:FF\r
    a=setup:actpass\r

    """

    /// A compact JWS whose payload names `role` and `peerKey` (the server's signature is not checked here).
    static func jws(role: String, peerKey: String, sid: String = "s1") -> String {
        func b64url(_ data: Data) -> String {
            data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        let payload = try! JSONSerialization.data(withJSONObject: ["sid": sid, "role": role, "dev": "device-1", "peer": "device-2",
                                                                    "peerKey": peerKey, "scope": "full", "iat": 1_800_000_000,
                                                                    "exp": 1_800_000_060, "jti": "j1"])
        return "\(b64url(Data(#"{"alg":"ES256"}"#.utf8))).\(b64url(payload)).c2ln"
    }

    @Test func fingerprintsAreEveryFingerprintLineInOrder() {
        #expect(TicketSignaling.fingerprint(ofSDP: Self.sdp) == "sha-256 AA:BB:CC,sha-256 DD:EE:FF")
        #expect(TicketSignaling.fingerprint(ofSDP: "v=0\na=fingerprint:sha-256 01:02\n") == "sha-256 01:02")
        #expect(TicketSignaling.fingerprint(ofSDP: "v=0\r\na=setup:active\r\n") == nil)
    }

    @Test func fpSigSignsSessionRoleAndFingerprint() async throws {
        let signer = SoftwareTicketSigner()
        let message = TicketSignaling.fingerprintMessage(sessionID: "s1", role: "host", fingerprint: "sha-256 AA")
        #expect(String(decoding: message, as: UTF8.self) == "s1|host|sha-256 AA")
        let fpSig = try await signer.sign(message).base64EncodedString()
        #expect(TicketSignaling.verify(fpSig: fpSig, sessionID: "s1", role: "host", fingerprint: "sha-256 AA", peerKey: signer.publicKey))
        #expect(!TicketSignaling.verify(fpSig: fpSig, sessionID: "s1", role: "viewer", fingerprint: "sha-256 AA", peerKey: signer.publicKey))
        #expect(!TicketSignaling.verify(fpSig: fpSig, sessionID: "s2", role: "host", fingerprint: "sha-256 AA", peerKey: signer.publicKey))
        #expect(!TicketSignaling.verify(fpSig: fpSig, sessionID: "s1", role: "host", fingerprint: "sha-256 AB", peerKey: signer.publicKey))
        #expect(!TicketSignaling.verify(fpSig: fpSig, sessionID: "s1", role: "host", fingerprint: "sha-256 AA",
                                        peerKey: SoftwareTicketSigner().publicKey))
    }

    @Test func theTicketPayloadIsRead() throws {
        let ticket = try TicketSignaling.Ticket(jws: Self.jws(role: "viewer", peerKey: "PEER"))
        #expect(ticket.sessionID == "s1" && ticket.role == "viewer" && ticket.peerRole == "host" && ticket.peerKey == "PEER")
        #expect(ticket.expires == Date(timeIntervalSince1970: 1_800_000_060))
        #expect(throws: ScreenSignalingError.self) { try TicketSignaling.Ticket(jws: "not-a-jws") }
        #expect(throws: ScreenSignalingError.badTicket("the ticket names another peer key")) {
            try TicketSignaling(ticket: Self.jws(role: "viewer", peerKey: "PEER"), signalURL: URL(string: "wss://hub/v1/sessions/s1/ws")!,
                                signer: SoftwareTicketSigner(), iceServers: [], expectedPeerKey: "OTHER")
        }
    }

    /// The viewer: opens the ticket URL with device headers, offers with its fpSig, accepts a signed answer.
    @Test(.timeLimit(.minutes(1))) func aViewerSignsItsOfferAndVerifiesTheAnswer() async throws {
        let viewer = SoftwareTicketSigner(), host = SoftwareTicketSigner()
        let socket = FakeSignalSocket()
        let opened = RequestBox()
        let relays = [ICEServerConfig(urls: ["turn:relay.example:3478"], username: "u", credential: "c")]
        let signaling = try TicketSignaling(ticket: Self.jws(role: "viewer", peerKey: host.publicKey),
                                            signalURL: URL(string: "wss://hub.example/v1/sessions/s1/ws")!, signer: viewer,
                                            iceServers: relays, expectedPeerKey: host.publicKey) { request in
            opened.set(request)
            return socket
        }
        #expect(signaling.endsSessionOnClose)
        #expect(try await signaling.iceServers() == relays)
        var messages = signaling.messages().makeAsyncIterator()
        #expect(try await messages.next() == .hello(peerPresent: true))
        let request = try #require(opened.value)
        #expect(request.url?.absoluteString.hasPrefix("wss://hub.example/v1/sessions/s1/ws?ticket=") == true)
        #expect(request.value(forHTTPHeaderField: "X-Device-Sig") == "sig-of-/v1/sessions/s1/ws")

        try await signaling.send(.offer(Self.sdp))
        let offer = try #require(socket.sent.first.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] })
        #expect(offer["type"] as? String == "offer" && offer["sdp"] as? String == Self.sdp)
        #expect(TicketSignaling.verify(fpSig: offer["fpSig"] as? String ?? "", sessionID: "s1", role: "viewer",
                                       fingerprint: "sha-256 AA:BB:CC,sha-256 DD:EE:FF", peerKey: viewer.publicKey))

        let fpSig = try await host.sign(TicketSignaling.fingerprintMessage(sessionID: "s1", role: "host",
                                                                            fingerprint: "sha-256 AA:BB:CC,sha-256 DD:EE:FF"))
        let answer = try JSONSerialization.data(withJSONObject: ["type": "answer", "sdp": Self.sdp, "fpSig": fpSig.base64EncodedString()])
        socket.deliver(String(decoding: answer, as: UTF8.self))
        #expect(try await messages.next() == .answer(Self.sdp))
        socket.deliver(#"{"type":"candidate","candidate":"candidate:1 1 udp 1 10.0.0.1 5000 typ host","sdpMid":"0","sdpMLineIndex":0}"#)
        #expect(try await messages.next() == .candidate(ScreenICECandidate(candidate: "candidate:1 1 udp 1 10.0.0.1 5000 typ host",
                                                                           sdpMid: "0", sdpMLineIndex: 0)))
        socket.deliver(#"{"type":"bye"}"#)
        #expect(try await messages.next() == .bye)
        #expect(try await messages.next() == nil)
    }

    /// The host: an offer whose fpSig is not the ticket's peer's aborts the session.
    @Test(.timeLimit(.minutes(1))) func aMismatchedFingerprintAborts() async throws {
        let host = SoftwareTicketSigner(), viewer = SoftwareTicketSigner(), impostor = SoftwareTicketSigner()
        let socket = FakeSignalSocket()
        let signaling = try TicketSignaling(ticket: Self.jws(role: "host", peerKey: viewer.publicKey),
                                            signalURL: URL(string: "wss://hub.example/v1/sessions/s1/ws")!, signer: host,
                                            iceServers: []) { _ in socket }
        var messages = signaling.messages().makeAsyncIterator()
        #expect(try await messages.next() == .hello(peerPresent: false))
        let forged = try await impostor.sign(TicketSignaling.fingerprintMessage(sessionID: "s1", role: "viewer",
                                                                                fingerprint: "sha-256 AA:BB:CC,sha-256 DD:EE:FF"))
        let offer = try JSONSerialization.data(withJSONObject: ["type": "offer", "sdp": Self.sdp, "fpSig": forged.base64EncodedString()])
        socket.deliver(String(decoding: offer, as: UTF8.self))
        await #expect(throws: ScreenSignalingError.fingerprintMismatch) { _ = try await messages.next() }
        #expect(socket.sent.contains(#"{"type":"bye"}"#))
        #expect(socket.closed)
    }

    /// The session's network path, once known, goes to the hub (`sessions.path`).
    @Test(.timeLimit(.minutes(1))) func thePathIsReported() async throws {
        let socket = FakeSignalSocket()
        let signaling = try TicketSignaling(ticket: Self.jws(role: "viewer", peerKey: SoftwareTicketSigner().publicKey),
                                            signalURL: URL(string: "wss://hub.example/v1/sessions/s1/ws")!,
                                            signer: SoftwareTicketSigner(), iceServers: []) { _ in socket }
        var messages = signaling.messages().makeAsyncIterator()
        _ = try await messages.next()
        try await signaling.send(.path(relay: true))
        try await signaling.send(.path(relay: false))
        #expect(socket.sent == [#"{"type":"path","path":"relay"}"#, #"{"type":"path","path":"direct"}"#])
    }

    @Test(.timeLimit(.minutes(1))) func anOfferWithoutFpSigAborts() async throws {
        let socket = FakeSignalSocket()
        let signaling = try TicketSignaling(ticket: Self.jws(role: "host", peerKey: SoftwareTicketSigner().publicKey),
                                            signalURL: URL(string: "wss://hub.example/v1/sessions/s1/ws")!,
                                            signer: SoftwareTicketSigner(), iceServers: []) { _ in socket }
        var messages = signaling.messages().makeAsyncIterator()
        _ = try await messages.next()
        let offer = try JSONSerialization.data(withJSONObject: ["type": "offer", "sdp": Self.sdp])
        socket.deliver(String(decoding: offer, as: UTF8.self))
        await #expect(throws: ScreenSignalingError.missingFingerprint) { _ = try await messages.next() }
    }

    /// A dropped Session DO socket (this device's network) ends signaling,
    /// not the session: a live peer connection lives on, and the hub's
    /// pushes or WebRTC itself end it. Only a `bye` frame is the session's end.
    @Test(.timeLimit(.minutes(1))) func aClosedSocketEndsSignalingNotTheSession() async throws {
        let socket = FakeSignalSocket()
        let signaling = try TicketSignaling(ticket: Self.jws(role: "viewer", peerKey: SoftwareTicketSigner().publicKey),
                                            signalURL: URL(string: "wss://hub.example/v1/sessions/s1/ws")!,
                                            signer: SoftwareTicketSigner(), iceServers: []) { _ in socket }
        var messages = signaling.messages().makeAsyncIterator()
        _ = try await messages.next()
        socket.close()
        #expect(try await messages.next() == nil)
    }

    /// A viewer that leaves says bye on the data channel: the host ends at once (view-only too).
    @Test func aByeEndsTheHostsSession() {
        #expect(ScreenStreamHost.endsSession(ScreenInput(t: "bye")))
        #expect(!ScreenStreamHost.endsSession(ScreenInput(t: "move", x: 0, y: 0)))
        #expect(ScreenStreamViewer.byeMessage == #"{"t":"bye"}"#)
    }

    @Test func roomMessagesMapToSignals() {
        #expect(RoomSignaling.signal(SignalMessage(type: "hello", peer: true)) == .hello(peerPresent: true))
        #expect(RoomSignaling.signal(SignalMessage(type: "hello")) == .hello(peerPresent: false))
        #expect(RoomSignaling.signal(SignalMessage(type: "peer-joined")) == .peerJoined)
        #expect(RoomSignaling.signal(SignalMessage(type: "peer-left")) == .peerLeft)
        #expect(RoomSignaling.signal(SignalMessage(type: "offer", sdp: "x")) == .offer("x"))
        #expect(RoomSignaling.signal(SignalMessage(type: "answer", sdp: "y")) == .answer("y"))
        #expect(RoomSignaling.signal(SignalMessage(type: "candidate", candidate: "c", sdpMid: "0", sdpMLineIndex: 0))
            == .candidate(ScreenICECandidate(candidate: "c", sdpMid: "0", sdpMLineIndex: 0)))
        #expect(RoomSignaling.signal(SignalMessage(type: "other")) == nil)
    }
}

/// Records what reaches the screen source.
final class RecordingBackend: ScreenBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var inputs: [String] = []
    private var selections: [Int] = []
    var handled: [String] { lock.withLock { inputs } }
    var selected: [Int] { lock.withLock { selections } }

    func start(frame: @escaping @Sendable (CVPixelBuffer, CGRect) -> Void, displays: @escaping @Sendable ([CGSize], Int) -> Void) async throws {}
    func select(display index: Int) { lock.withLock { selections.append(index) } }
    func handle(_ input: ScreenInput) { lock.withLock { inputs.append(input.t) } }
    func stop() {}
}

struct ViewOnlyHostTests {
    static let inputs = [
        ScreenInput(t: "move", x: 0.5, y: 0.5, b: 1), ScreenInput(t: "scroll", dy: 3), ScreenInput(t: "key", k: 0x61, d: true),
        ScreenInput(t: "chord", k: 0x71, m: [0xFFE7]), ScreenInput(t: "text", s: "rm -rf"), ScreenInput(t: "refresh"),
        ScreenInput(t: "display", i: 1),
    ]

    @Test func aViewOnlyHostIgnoresAllInput() {
        let backend = RecordingBackend()
        let host = ScreenStreamHost(name: "Studio", viewOnly: true, backend: { backend }, log: { _ in })
        for input in Self.inputs { host.deliver(input, to: backend) }
        #expect(backend.handled == ["refresh"])
        // Choosing which display to watch is not input to the Mac.
        #expect(backend.selected == [1])
    }

    @Test func aFullHostPassesInputThrough() {
        let backend = RecordingBackend()
        let host = ScreenStreamHost(name: "Studio", backend: { backend }, log: { _ in })
        for input in Self.inputs { host.deliver(input, to: backend) }
        #expect(backend.handled == ["move", "scroll", "key", "chord", "text", "refresh"])
        #expect(backend.selected == [1])
    }
}
