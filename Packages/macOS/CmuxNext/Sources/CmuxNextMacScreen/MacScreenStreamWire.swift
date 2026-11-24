import CmuxScreenKit
import CoreGraphics
import Foundation

/// One JSON line between the app and its WebRTC stream host child (``MacScreenStreamProcess`` and
/// ``MacScreenStreamChild``): the iPhone viewer's session served by `ScreenStreamHost` in a process
/// the Screen Sharing helper started, so its capture and input use the helper's grants. Every field
/// is optional; a line carries the ones it means. The viewer never sees this: its signaling is still
/// the session's own, relayed by the app, so viewers in the field are unchanged.
///
/// App to child: `setup` (first), `signal` (the viewer's), `ice` (the answer to `ice_request`),
/// `exclude_windows` (the whole list, SECURITY) and `stop`. Child to app: `signal` (to the viewer),
/// `ready` (the first line: the grants macOS reads for it, the helper's), `ice_request`, `event`, `close`
/// and `done` (the last line).
nonisolated struct MacScreenStreamLine: Codable, Sendable, Equatable {
    struct Setup: Codable, Sendable, Equatable {
        /// The name the viewer shows for this Mac.
        var name: String
        var viewOnly: Bool
        /// ``ScreenSignaling/endsSessionOnClose`` of the session's signaling.
        var endsSessionOnClose: Bool

        enum CodingKeys: String, CodingKey {
            case name
            case viewOnly = "view_only"
            case endsSessionOnClose = "ends_session_on_close"
        }
    }

    /// A ``ScreenSignal`` on the wire.
    struct Signal: Codable, Sendable, Equatable {
        var type: String
        var sdp: String?
        var candidate: String?
        var sdpMid: String?
        var sdpMLineIndex: Int32?
        var peerPresent: Bool?
        var relay: Bool?

        enum CodingKeys: String, CodingKey {
            case type, sdp, candidate, relay
            case sdpMid = "sdp_mid"
            case sdpMLineIndex = "sdp_mline_index"
            case peerPresent = "peer_present"
        }

        init(type: String, sdp: String? = nil, candidate: String? = nil, sdpMid: String? = nil,
             sdpMLineIndex: Int32? = nil, peerPresent: Bool? = nil, relay: Bool? = nil) {
            self.type = type
            self.sdp = sdp
            self.candidate = candidate
            self.sdpMid = sdpMid
            self.sdpMLineIndex = sdpMLineIndex
            self.peerPresent = peerPresent
            self.relay = relay
        }

        init(_ signal: ScreenSignal) {
            switch signal {
            case let .hello(peerPresent): self.init(type: "hello", peerPresent: peerPresent)
            case .peerJoined: self.init(type: "peer-joined")
            case .peerLeft: self.init(type: "peer-left")
            case let .offer(sdp): self.init(type: "offer", sdp: sdp)
            case let .answer(sdp): self.init(type: "answer", sdp: sdp)
            case let .candidate(candidate):
                self.init(type: "candidate", candidate: candidate.candidate, sdpMid: candidate.sdpMid,
                          sdpMLineIndex: candidate.sdpMLineIndex)
            case .bye: self.init(type: "bye")
            case let .path(relay): self.init(type: "path", relay: relay)
            }
        }

        /// The signal, or nil for a type this build does not know.
        var signal: ScreenSignal? {
            switch type {
            case "hello": .hello(peerPresent: peerPresent == true)
            case "peer-joined": .peerJoined
            case "peer-left": .peerLeft
            case "offer": sdp.map(ScreenSignal.offer)
            case "answer": sdp.map(ScreenSignal.answer)
            case "candidate": candidate.map { .candidate(ScreenICECandidate(candidate: $0, sdpMid: sdpMid, sdpMLineIndex: sdpMLineIndex)) }
            case "bye": .bye
            case "path": relay.map { .path(relay: $0) }
            default: nil
            }
        }
    }

    /// The answer to one `ice_request`: the session's ICE servers, or why there are none.
    struct ICE: Codable, Sendable, Equatable {
        var id: Int
        var servers: [ICEServerConfig]?
        var error: String?
    }

    /// The child's ``ScreenStreamHost/Event``.
    enum Event: String, Codable, Sendable, Equatable {
        case viewerConnected = "viewer_connected"
        case viewerEnded = "viewer_ended"
        case sourceFailed = "source_failed"
    }

    /// The grants macOS reports for the child (its responsible process's: the helper's).
    struct Ready: Codable, Sendable, Equatable {
        var screenRecording: Bool
        var accessibility: Bool

        enum CodingKeys: String, CodingKey {
            case screenRecording = "screen_recording"
            case accessibility
        }
    }

    /// The session's end: nil `error` when `serve` returned.
    struct Done: Codable, Sendable, Equatable {
        var error: String?
    }

    var setup: Setup?
    var signal: Signal?
    var ice: ICE?
    var excludeWindows: [CGWindowID]?
    var stop: Bool?
    var iceRequest: Int?
    var event: Event?
    /// The `source_failed` event's message.
    var message: String?
    var close: Bool?
    var done: Done?
    var ready: Ready?

    enum CodingKeys: String, CodingKey {
        case setup, signal, ice, stop, event, message, close, done, ready
        case excludeWindows = "exclude_windows"
        case iceRequest = "ice_request"
    }

    init(setup: Setup? = nil, signal: Signal? = nil, ice: ICE? = nil, excludeWindows: [CGWindowID]? = nil,
         stop: Bool? = nil, iceRequest: Int? = nil, event: Event? = nil, message: String? = nil,
         close: Bool? = nil, done: Done? = nil, ready: Ready? = nil) {
        self.setup = setup
        self.signal = signal
        self.ice = ice
        self.excludeWindows = excludeWindows
        self.stop = stop
        self.iceRequest = iceRequest
        self.event = event
        self.message = message
        self.close = close
        self.done = done
        self.ready = ready
    }

    /// The line's JSON with its newline.
    var encoded: Data? {
        guard var data = try? JSONEncoder().encode(self) else { return nil }
        data.append(UInt8(ascii: "\n"))
        return data
    }
}

/// Splits a byte stream into JSON lines and decodes each (a line that does not decode is skipped).
nonisolated struct MacScreenStreamLineSplitter {
    private var pending = Data()
    /// A line longer than this is dropped: no signal is near it (an SDP is a few KB).
    static let maximumLine = 1 << 20

    mutating func push(_ data: Data) -> [MacScreenStreamLine] {
        pending.append(data)
        var lines: [MacScreenStreamLine] = []
        while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
            let line = pending[pending.startIndex ..< newline]
            pending.removeSubrange(pending.startIndex ... newline)
            if let decoded = try? JSONDecoder().decode(MacScreenStreamLine.self, from: Data(line)) { lines.append(decoded) }
        }
        if pending.count > Self.maximumLine { pending.removeAll() }
        return lines
    }
}
