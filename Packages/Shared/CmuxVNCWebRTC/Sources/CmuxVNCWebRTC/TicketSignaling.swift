import CryptoKit
import Foundation

/// This device's signing key, as the device hub knows it (the app supplies
/// its Secure Enclave identity).
public protocol ScreenTicketSigner: Sendable {
    /// The device headers (`X-Device-Id`, `X-Device-Ts`, `X-Device-Sig`)
    /// for a GET of `url` with no body.
    func deviceHeaders(for url: URL) async throws -> [String: String]
    /// The raw r||s (64 bytes) ECDSA-P256-SHA256 signature of `message`.
    func sign(_ message: Data) async throws -> Data
}

/// One text WebSocket to the Session DO.
public protocol ScreenSignalSocket: Sendable {
    /// The next text frame; throws when the socket closes.
    func receive() async throws -> String
    func send(_ text: String) async throws
    func close()
}

/// Device hub session signaling (docs/device-hub/PROTOCOL.md, Session flow):
/// opens `signalURL?ticket=<jws>` with the device headers, signs this side's
/// DTLS fingerprint into every offer and answer (`fpSig` over
/// `"<sid>|<role>|<fingerprint>"`, `role` the sender's), and verifies the
/// peer's against the ticket's `peerKey`. A mismatch aborts: the stream
/// throws ``ScreenSignalingError/fingerprintMismatch``, `bye` is sent and the
/// socket closed. The ticket admits once, so no new signaling follows a
/// closed socket; a peer connection already open outlives it.
// crash-allow: `socket` and `closed` are read and written only under `lock`; every other field is a `let`.
public final class TicketSignaling: ScreenSignaling, @unchecked Sendable {
    // @unchecked: `socket` and `opened` are behind `lock`.

    /// What the ticket's (unverified, server-signed) payload says; the Session DO checks it.
    public struct Ticket: Sendable, Equatable {
        public var sessionID: String
        /// `viewer` or `host`: this device's role.
        public var role: String
        /// base64 X9.63 signing key of the other device.
        public var peerKey: String
        public var scope: String?
        public var expires: Date?

        /// The other side's role.
        public var peerRole: String { role == "viewer" ? "host" : "viewer" }

        /// Reads a compact JWS's payload.
        public init(jws: String) throws {
            let parts = jws.split(separator: ".", omittingEmptySubsequences: false)
            guard parts.count == 3, let data = Self.base64URL(String(parts[1])),
                  let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw ScreenSignalingError.badTicket("not a compact JWS")
            }
            guard let sid = payload["sid"] as? String, let role = payload["role"] as? String, role == "viewer" || role == "host",
                  let peerKey = payload["peerKey"] as? String else {
                throw ScreenSignalingError.badTicket("no sid, role or peerKey")
            }
            sessionID = sid
            self.role = role
            self.peerKey = peerKey
            scope = payload["scope"] as? String
            expires = (payload["exp"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
        }

        static func base64URL(_ text: String) -> Data? {
            var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
            return Data(base64Encoded: base64)
        }
    }

    public let ticket: Ticket
    public let socketURL: URL
    private let signer: any ScreenTicketSigner
    private let servers: [ICEServerConfig]
    private let connect: @Sendable (URLRequest) async throws -> any ScreenSignalSocket
    private let lock = NSLock()
    private var socket: (any ScreenSignalSocket)?
    private var closed = false

    /// `jws` and `signalURL` come from the hub's `session.ticket` push;
    /// `expectedPeerKey` (the push's `peer.signingKey`) must match the
    /// ticket's. `iceServers`: the session's relays (the user's, then cmux's).
    /// `connect` opens the socket (tests inject one; URLSession otherwise).
    public init(ticket jws: String, signalURL: URL, signer: any ScreenTicketSigner, iceServers: [ICEServerConfig],
                expectedPeerKey: String? = nil,
                connect: (@Sendable (URLRequest) async throws -> any ScreenSignalSocket)? = nil) throws {
        let ticket = try Ticket(jws: jws)
        if let expectedPeerKey, expectedPeerKey != ticket.peerKey {
            throw ScreenSignalingError.badTicket("the ticket names another peer key")
        }
        self.ticket = ticket
        guard var components = URLComponents(url: signalURL, resolvingAgainstBaseURL: true) else {
            throw ScreenSignalingError.badTicket("bad signal URL")
        }
        let query = (components.queryItems ?? []) + [URLQueryItem(name: "ticket", value: jws)]
        components.queryItems = query
        guard let url = components.url else { throw ScreenSignalingError.badTicket("bad signal URL") }
        socketURL = url
        self.signer = signer
        servers = iceServers
        self.connect = connect ?? URLSessionSignalSocket.open
    }

    public var endsSessionOnClose: Bool { true }

    public func iceServers() async throws -> [ICEServerConfig] { servers }

    public func messages() -> AsyncThrowingStream<ScreenSignal, any Error> {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: ScreenSignal.self, bufferingPolicy: .bufferingNewest(256))
        let task = Task { [self] in
            do {
                var request = URLRequest(url: socketURL)
                for (name, value) in try await signer.deviceHeaders(for: socketURL) { request.setValue(value, forHTTPHeaderField: name) }
                let socket = try await connect(request)
                let alreadyClosed = lock.withLock { () -> Bool in
                    self.socket = socket
                    return closed
                }
                if alreadyClosed {
                    socket.close()
                    continuation.finish()
                    return
                }
                // The Session DO queues frames until the peer connects, so a viewer offers at once.
                continuation.yield(.hello(peerPresent: ticket.role == "viewer"))
                while !Task.isCancelled {
                    let text: String
                    do { text = try await socket.receive() } catch {
                        // The socket closed (this device's network, or the server).
                        // Signaling is over, not the session: a live peer
                        // connection lives on; the hub's pushes or WebRTC end it.
                        break
                    }
                    guard let signal = try receive(text) else { continue }
                    continuation.yield(signal)
                    if signal == .bye { break }
                }
                continuation.finish()
            } catch {
                if error as? ScreenSignalingError == .fingerprintMismatch || error as? ScreenSignalingError == .missingFingerprint {
                    try? await lock.withLock({ socket })?.send(#"{"type":"bye"}"#)
                }
                close()
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    /// One frame from the peer; nil for a type this side ignores.
    func receive(_ text: String) throws -> ScreenSignal? {
        guard let message = try? JSONDecoder().decode(Frame.self, from: Data(text.utf8)) else { return nil }
        switch message.type {
        case "offer", "answer":
            guard let sdp = message.sdp, let fpSig = message.fpSig, let fingerprint = Self.fingerprint(ofSDP: sdp) else {
                throw ScreenSignalingError.missingFingerprint
            }
            guard Self.verify(fpSig: fpSig, sessionID: ticket.sessionID, role: ticket.peerRole, fingerprint: fingerprint,
                              peerKey: ticket.peerKey) else { throw ScreenSignalingError.fingerprintMismatch }
            return message.type == "offer" ? .offer(sdp) : .answer(sdp)
        case "candidate":
            guard let candidate = message.candidate else { return nil }
            return .candidate(ScreenICECandidate(candidate: candidate, sdpMid: message.sdpMid, sdpMLineIndex: message.sdpMLineIndex))
        case "bye": return .bye
        case "peer-joined": return .peerJoined
        default: return nil
        }
    }

    public func send(_ signal: ScreenSignal) async throws {
        let frame: Frame
        switch signal {
        case let .offer(sdp):
            frame = try await signed("offer", sdp)
        case let .answer(sdp):
            frame = try await signed("answer", sdp)
        case let .candidate(candidate):
            frame = Frame(type: "candidate", candidate: candidate.candidate, sdpMid: candidate.sdpMid, sdpMLineIndex: candidate.sdpMLineIndex)
        case .bye:
            frame = Frame(type: "bye")
        case let .path(relay):
            // `{type:'path', path:'direct'|'relay'}`: the hub stores it, the peer never sees it.
            guard let socket = lock.withLock({ socket }) else { return }
            try await socket.send(#"{"type":"path","path":"\#(relay ? "relay" : "direct")"}"#)
            return
        case .hello, .peerJoined, .peerLeft:
            return
        }
        guard let socket = lock.withLock({ socket }) else { throw VNCWebRTCError.signaling("the session socket is not open") }
        let data = try JSONEncoder().encode(frame)
        try await socket.send(String(decoding: data, as: UTF8.self))
    }

    /// An offer or answer with this side's `fpSig`.
    private func signed(_ type: String, _ sdp: String) async throws -> Frame {
        guard let fingerprint = Self.fingerprint(ofSDP: sdp) else { throw ScreenSignalingError.missingFingerprint }
        let message = Self.fingerprintMessage(sessionID: ticket.sessionID, role: ticket.role, fingerprint: fingerprint)
        return Frame(type: type, sdp: sdp, fpSig: try await signer.sign(message).base64EncodedString())
    }

    public func close() {
        let socket = lock.withLock { () -> (any ScreenSignalSocket)? in
            closed = true
            return self.socket
        }
        socket?.close()
    }

    struct Frame: Codable {
        var type: String
        var sdp: String?
        var fpSig: String?
        var candidate: String?
        var sdpMid: String?
        var sdpMLineIndex: Int32?
    }

    // MARK: Fingerprints

    /// The values of the SDP's `a=fingerprint:` lines, in order, joined with
    /// `,` (`sha-256 AB:CD:…`); nil when it has none.
    public static func fingerprint(ofSDP sdp: String) -> String? {
        let prefix = "a=fingerprint:"
        let values = sdp.split(whereSeparator: \.isNewline).compactMap { line -> String? in
            let line = line.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix(prefix) else { return nil }
            return String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        }
        return values.isEmpty ? nil : values.joined(separator: ",")
    }

    /// The bytes an `fpSig` signs: `"<sid>|<role>|<fingerprint>"`, `role` the signer's.
    public static func fingerprintMessage(sessionID: String, role: String, fingerprint: String) -> Data {
        Data("\(sessionID)|\(role)|\(fingerprint)".utf8)
    }

    /// Whether `fpSig` (base64 raw r||s) is `peerKey`'s (base64 X9.63) signature for `role`'s fingerprint.
    public static func verify(fpSig: String, sessionID: String, role: String, fingerprint: String, peerKey: String) -> Bool {
        guard let raw = Data(base64Encoded: fpSig), let keyData = Data(base64Encoded: peerKey),
              let key = try? P256.Signing.PublicKey(x963Representation: keyData),
              let signature = try? P256.Signing.ECDSASignature(rawRepresentation: raw) else { return false }
        return key.isValidSignature(signature, for: fingerprintMessage(sessionID: sessionID, role: role, fingerprint: fingerprint))
    }
}

/// The Session DO socket over URLSession (no cache, no cookies).
struct URLSessionSignalSocket: ScreenSignalSocket {
    let task: URLSessionWebSocketTask

    @Sendable static func open(_ request: URLRequest) async throws -> any ScreenSignalSocket {
        let task = SignalSocket.session.webSocketTask(with: request)
        task.maximumMessageSize = 1 << 20
        task.resume()
        return URLSessionSignalSocket(task: task)
    }

    func receive() async throws -> String {
        switch try await task.receive() {
        case let .string(text): return text
        case let .data(data): return String(decoding: data, as: UTF8.self)
        @unknown default: return ""
        }
    }

    func send(_ text: String) async throws {
        try await task.send(.string(text))
    }

    func close() {
        task.cancel(with: .normalClosure, reason: nil)
    }
}
