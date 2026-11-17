import Foundation

/// A ``ScreenSignal`` as one JSON object, for a session whose signaling and capture run in two
/// processes: the cmux app keeps a Mac Screen session's ticket signaling, and the cmux Computer
/// Use helper's Screen Sharing worker captures, so the signals cross a local socket between them.
/// One codec for both ends.
public enum ScreenSignalWire {
    /// `signal` as a JSON object (`type` names it, as the hub's frames do).
    public static func fields(_ signal: ScreenSignal) -> [String: Any] {
        switch signal {
        case let .hello(peerPresent): ["type": "hello", "peer": peerPresent]
        case .peerJoined: ["type": "peer-joined"]
        case .peerLeft: ["type": "peer-left"]
        case let .offer(sdp): ["type": "offer", "sdp": sdp]
        case let .answer(sdp): ["type": "answer", "sdp": sdp]
        case let .candidate(candidate):
            ["type": "candidate", "candidate": candidate.candidate,
             "sdpMid": candidate.sdpMid.map { $0 as Any } ?? NSNull(),
             "sdpMLineIndex": candidate.sdpMLineIndex.map { NSNumber(value: $0) as Any } ?? NSNull()]
        case .bye: ["type": "bye"]
        case let .path(relay): ["type": "path", "relay": relay]
        }
    }

    /// The signal `fields` names; nil for an object that is not one.
    public static func signal(_ fields: [String: Any]) -> ScreenSignal? {
        switch fields["type"] as? String {
        case "hello": .hello(peerPresent: fields["peer"] as? Bool ?? false)
        case "peer-joined": .peerJoined
        case "peer-left": .peerLeft
        case "offer": (fields["sdp"] as? String).map(ScreenSignal.offer)
        case "answer": (fields["sdp"] as? String).map(ScreenSignal.answer)
        case "candidate":
            (fields["candidate"] as? String).map {
                .candidate(ScreenICECandidate(candidate: $0, sdpMid: fields["sdpMid"] as? String,
                                              sdpMLineIndex: (fields["sdpMLineIndex"] as? NSNumber).map { $0.int32Value }))
            }
        case "bye": .bye
        case "path": .path(relay: fields["relay"] as? Bool ?? false)
        default: nil
        }
    }

    /// ICE servers as JSON objects (`urls`, `username`, `credential`).
    public static func fields(_ servers: [ICEServerConfig]) -> [[String: Any]] {
        servers.map { server in
            var fields: [String: Any] = ["urls": server.urls]
            if let username = server.username { fields["username"] = username }
            if let credential = server.credential { fields["credential"] = credential }
            return fields
        }
    }

    /// The ICE servers in `list`; entries without `urls` are left out.
    public static func servers(_ list: Any?) -> [ICEServerConfig] {
        (list as? [[String: Any]] ?? []).compactMap { fields in
            guard let urls = fields["urls"] as? [String] else { return nil }
            return ICEServerConfig(urls: urls, username: fields["username"] as? String, credential: fields["credential"] as? String)
        }
    }
}
