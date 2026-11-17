import Foundation

/// The cmux app's attached Mac Screen capture, served by cmux Remote's Screen Sharing worker
/// (docs/cmux-remote.md, "Attached capture"). The app keeps the device hub ticket, its
/// signaling and the approval UI; capture, encoding and input injection run in the worker, so
/// macOS checks cmux Remote's Screen Recording and Accessibility, never the app's. Each session
/// is one dedicated app channel (`screen-sharing`) whose first request names its kind:
///
/// - ``rdServe``: the worker starts its bundled cmux.rd/1 host (`cmux-screen-sharing serve`) and
///   the channel becomes that process's stdin and stdout, byte for byte. The app keeps driving
///   it exactly as it drives a local host (setup, candidates, `stop`), so the viewer's wire is
///   unchanged.
/// - ``webRTCServe``: the worker serves a WebRTC viewer with its `ScreenStreamHost`; the channel
///   carries the session's signals both ways as ``line(_:)`` objects, plus the host's events.
///
/// Closing the channel ends the session in the worker. A worker that does not list a kind in
/// its status `serves` (an older pinned cmux Remote) answers `unknown_method`.
public enum AttachedScreenHost {
    /// The request that turns a channel into a cmux.rd/1 host process's stdio.
    public static let rdServe = "screen.rd_serve"
    /// The request that turns a channel into a WebRTC session's signaling.
    public static let webRTCServe = "screen.webrtc_serve"
    /// The kinds a worker lists in its status `serves`.
    public static let rdKind = "cmux.rd/1"
    public static let webRTCKind = "webrtc"

    /// The host's events on a WebRTC channel (`{"event": …}`).
    public enum Event: Sendable, Equatable {
        case viewerConnected
        case viewerEnded(String)
        case sourceFailed(String)

        public var fields: [String: String] {
            switch self {
            case .viewerConnected: ["event": "viewer_connected"]
            case let .viewerEnded(reason): ["event": "viewer_ended", "reason": reason]
            case let .sourceFailed(message): ["event": "source_failed", "reason": message]
            }
        }

        public init?(fields: [String: Any]) {
            switch fields["event"] as? String {
            case "viewer_connected": self = .viewerConnected
            case "viewer_ended": self = .viewerEnded(fields["reason"] as? String ?? "")
            case "source_failed": self = .sourceFailed(fields["reason"] as? String ?? "")
            default: return nil
            }
        }
    }

    /// One signal as a channel line's object: `{"signal": {"type": …}}`.
    public static func line(_ signal: ScreenSignal) -> [String: Any] {
        ["signal": fields(signal)]
    }

    /// The signal a channel line carries, or nil (an event, or a signal this side does not know).
    public static func signal(_ line: [String: Any]) -> ScreenSignal? {
        (line["signal"] as? [String: Any]).flatMap(signal(fields:))
    }

    /// The line that says this side's signaling closed (a connected session outlives it).
    public static var signalingClosed: [String: Any] { ["signaling_closed": true] }

    static func fields(_ signal: ScreenSignal) -> [String: Any] {
        switch signal {
        case let .hello(peerPresent): ["type": "hello", "peer_present": peerPresent]
        case .peerJoined: ["type": "peer_joined"]
        case .peerLeft: ["type": "peer_left"]
        case let .offer(sdp): ["type": "offer", "sdp": sdp]
        case let .answer(sdp): ["type": "answer", "sdp": sdp]
        case let .candidate(candidate):
            ["type": "candidate", "candidate": candidate.candidate,
             "sdp_mid": candidate.sdpMid.map { $0 as Any } ?? NSNull(),
             "sdp_mline_index": candidate.sdpMLineIndex.map { Int($0) as Any } ?? NSNull()]
        case .bye: ["type": "bye"]
        case let .path(relay): ["type": "path", "relay": relay]
        }
    }

    static func signal(fields: [String: Any]) -> ScreenSignal? {
        switch fields["type"] as? String {
        case "hello": .hello(peerPresent: fields["peer_present"] as? Bool ?? false)
        case "peer_joined": .peerJoined
        case "peer_left": .peerLeft
        case "offer": (fields["sdp"] as? String).map(ScreenSignal.offer)
        case "answer": (fields["sdp"] as? String).map(ScreenSignal.answer)
        case "candidate":
            (fields["candidate"] as? String).map {
                .candidate(ScreenICECandidate(candidate: $0, sdpMid: fields["sdp_mid"] as? String,
                                              sdpMLineIndex: (fields["sdp_mline_index"] as? Int).map { Int32(clamping: $0) }))
            }
        case "bye": .bye
        case "path": .path(relay: fields["relay"] as? Bool ?? false)
        default: nil
        }
    }

    /// ICE servers as a request's `ice_servers`.
    public static func fields(_ servers: [ICEServerConfig]) -> [[String: Any]] {
        servers.map { server in
            var fields: [String: Any] = ["urls": server.urls]
            if let username = server.username { fields["username"] = username }
            if let credential = server.credential { fields["credential"] = credential }
            return fields
        }
    }

    public static func servers(_ fields: Any?) -> [ICEServerConfig] {
        (fields as? [[String: Any]] ?? []).compactMap { server in
            guard let urls = server["urls"] as? [String], !urls.isEmpty else { return nil }
            return ICEServerConfig(urls: urls, username: server["username"] as? String, credential: server["credential"] as? String)
        }
    }
}
