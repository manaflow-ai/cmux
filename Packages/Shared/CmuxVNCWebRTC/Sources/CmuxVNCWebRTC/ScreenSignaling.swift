import Foundation

/// One ICE candidate as signaling carries it.
public struct ScreenICECandidate: Sendable, Equatable {
    public var candidate: String
    public var sdpMid: String?
    public var sdpMLineIndex: Int32?

    public init(candidate: String, sdpMid: String?, sdpMLineIndex: Int32?) {
        self.candidate = candidate
        self.sdpMid = sdpMid
        self.sdpMLineIndex = sdpMLineIndex
    }

    init(_ message: SignalMessage) {
        self.init(candidate: message.candidate ?? "", sdpMid: message.sdpMid, sdpMLineIndex: message.sdpMLineIndex)
    }

    var message: SignalMessage {
        SignalMessage(type: "candidate", candidate: candidate, sdpMid: sdpMid, sdpMLineIndex: sdpMLineIndex)
    }
}

/// What host and viewer say to each other before WebRTC connects.
public enum ScreenSignal: Sendable, Equatable {
    /// This side is connected; `peerPresent`: the other side is too (a viewer then offers).
    case hello(peerPresent: Bool)
    /// The other side connected.
    case peerJoined
    /// The other side's signaling connection dropped (a connected stream lives on).
    case peerLeft
    case offer(String)
    case answer(String)
    case candidate(ScreenICECandidate)
    /// The session is over: the other side left it, or the server ended it.
    case bye
    /// This side's media path is known (sent only; a device hub records it as `sessions.path`).
    case path(relay: Bool)
}

/// How a screen stream's host and viewer reach each other before WebRTC
/// connects: a pairing link's room (``RoomSignaling``) or a device hub
/// session (``TicketSignaling``). One value is one connection.
public protocol ScreenSignaling: AnyObject, Sendable {
    /// Opens the connection; signals until it closes.
    func messages() -> AsyncThrowingStream<ScreenSignal, any Error>
    func send(_ signal: ScreenSignal) async throws
    /// The ICE servers (STUN, TURN relays) for this session.
    func iceServers() async throws -> [ICEServerConfig]
    func close()
    /// Whether this connection is the session: when it closes, the session
    /// ends (a device hub ticket admits once). A room is reopened instead,
    /// and a connected stream outlives it.
    var endsSessionOnClose: Bool { get }
}

public enum ScreenSignalingError: Error, Sendable, Equatable, CustomStringConvertible {
    /// The peer's `fpSig` did not verify with the key its ticket names: not the device the hub admitted.
    case fingerprintMismatch
    /// An offer or answer without a DTLS fingerprint or without `fpSig`.
    case missingFingerprint
    case badTicket(String)

    public var description: String {
        switch self {
        case .fingerprintMismatch: "the other device's DTLS fingerprint signature does not verify"
        case .missingFingerprint: "the other device's offer or answer has no signed DTLS fingerprint"
        case let .badTicket(detail): "session ticket: \(detail)"
        }
    }
}

/// The pairing link's room on the cmux-vnc-signal Worker (the behavior
/// ScreenStreamHost and ScreenStreamViewer have always had).
public final class RoomSignaling: ScreenSignaling {
    public let pairing: VNCPairing
    private let socket: SignalSocket

    /// `role`: `host` or `viewer`.
    public init(pairing: VNCPairing, role: String) {
        self.pairing = pairing
        socket = SignalSocket(pairing: pairing, role: role)
    }

    public var endsSessionOnClose: Bool { false }

    public func messages() -> AsyncThrowingStream<ScreenSignal, any Error> {
        let source = socket.messages()
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await message in source {
                        if let signal = Self.signal(message) { continuation.yield(signal) }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func signal(_ message: SignalMessage) -> ScreenSignal? {
        switch message.type {
        case "hello": .hello(peerPresent: message.peer == true)
        case "peer-joined": .peerJoined
        case "peer-left": .peerLeft
        case "offer": message.sdp.map(ScreenSignal.offer)
        case "answer": message.sdp.map(ScreenSignal.answer)
        case "candidate": .candidate(ScreenICECandidate(message))
        default: nil
        }
    }

    public func send(_ signal: ScreenSignal) async throws {
        switch signal {
        case let .offer(sdp): try await socket.send(SignalMessage(type: "offer", sdp: sdp))
        case let .answer(sdp): try await socket.send(SignalMessage(type: "answer", sdp: sdp))
        case let .candidate(candidate): try await socket.send(candidate.message)
        case .hello, .peerJoined, .peerLeft, .bye, .path: break
        }
    }

    public func iceServers() async throws -> [ICEServerConfig] {
        try await SignalSocket.iceServers(pairing)
    }

    public func close() {
        socket.close()
    }
}
