import Foundation

/// Which side of a link a device is. The Mac app is the `host`; a phone is a `client`.
public enum RTCRole: String, Codable, Sendable {
    case host
    case client
}

/// One online host as the backend lists it (`rtc.hosts`): a device is listed exactly while its
/// signaling socket is open.
public struct RTCHostInfo: Codable, Sendable, Hashable, Identifiable {
    public let peer: String
    public let name: String
    /// Build lane of the host app: `default`, `nightly`, `rc`, or a DEV tag.
    public let tag: String
    public let platform: String
    public let appVersion: String
    /// Epoch milliseconds when the host's socket said hello.
    public let since: Double

    public var id: String { peer }

    public init(peer: String, name: String, tag: String, platform: String, appVersion: String, since: Double) {
        self.peer = peer
        self.name = name
        self.tag = tag
        self.platform = platform
        self.appVersion = appVersion
        self.since = since
    }

    enum CodingKeys: String, CodingKey {
        case peer, name, tag, platform, since
        case appVersion = "app_version"
    }
}

/// Signaling payload kinds relayed between two peers.
public enum RTCSignalKind: String, Codable, Sendable {
    case offer
    case answer
    case candidate
    case bye
}

/// One relayed signaling message. `peer` is the recipient when sending and the sender
/// (stamped by the relay) when receiving.
public struct RTCSignalMessage: Sendable, Equatable {
    public var peer: String
    public var peerRole: RTCRole?
    public var session: String
    public var kind: RTCSignalKind
    public var sdp: String?
    public var candidate: String?
    public var sdpMid: String?
    public var sdpMLineIndex: Int32?
    public var reason: String?

    public init(peer: String, peerRole: RTCRole? = nil, session: String, kind: RTCSignalKind, sdp: String? = nil, candidate: String? = nil, sdpMid: String? = nil, sdpMLineIndex: Int32? = nil, reason: String? = nil) {
        self.peer = peer
        self.peerRole = peerRole
        self.session = session
        self.kind = kind
        self.sdp = sdp
        self.candidate = candidate
        self.sdpMid = sdpMid
        self.sdpMLineIndex = sdpMLineIndex
        self.reason = reason
    }
}

/// What this device announces in `rtc.hello`.
public struct RTCHello: Sendable, Equatable {
    public let role: RTCRole
    public let peer: String
    public let name: String
    public let tag: String
    public let platform: String
    public let appVersion: String

    public init(role: RTCRole, peer: String, name: String, tag: String, platform: String, appVersion: String) {
        self.role = role
        self.peer = peer
        self.name = name
        self.tag = tag
        self.platform = platform
        self.appVersion = appVersion
    }
}

/// A frame the backend sends on the user socket that this module understands.
public enum RTCServerFrame: Sendable, Equatable {
    case welcome(peer: String)
    case hosts([RTCHostInfo])
    case signal(RTCSignalMessage)
    case error(code: String, session: String?, peer: String?)
}

/// JSON codec for the `rtc.*` frames (backend/apps/api/src/rtc-signal.ts). Frames of other
/// types on the same socket (the owner's `welcome`, ledger events) decode to nil.
public enum RTCFrameCodec {
    public static func encode(_ hello: RTCHello) -> String {
        json([
            "t": "rtc.hello", "role": hello.role.rawValue, "peer": hello.peer, "name": hello.name,
            "tag": hello.tag, "platform": hello.platform, "app_version": hello.appVersion,
        ])
    }

    public static func encodeHostsRequest() -> String { json(["t": "rtc.hosts"]) }

    public static func encode(_ m: RTCSignalMessage) -> String {
        var frame: [String: Any] = ["t": "rtc.signal", "to": m.peer, "session": m.session, "kind": m.kind.rawValue]
        if let sdp = m.sdp { frame["sdp"] = sdp }
        if let candidate = m.candidate { frame["candidate"] = candidate }
        if let mid = m.sdpMid { frame["sdp_mid"] = mid }
        if let index = m.sdpMLineIndex { frame["sdp_mline_index"] = Int(index) }
        if let reason = m.reason { frame["reason"] = reason }
        return json(frame)
    }

    public static func decode(_ text: String) -> RTCServerFrame? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["t"] as? String
        else { return nil }
        switch type {
        case "rtc.welcome":
            guard let peer = object["peer"] as? String else { return nil }
            return .welcome(peer: peer)
        case "rtc.hosts":
            guard let raw = object["hosts"],
                  let hostsData = try? JSONSerialization.data(withJSONObject: raw),
                  let hosts = try? JSONDecoder().decode([RTCHostInfo].self, from: hostsData)
            else { return nil }
            return .hosts(hosts)
        case "rtc.signal":
            guard let from = object["from"] as? String,
                  let session = object["session"] as? String,
                  let kind = (object["kind"] as? String).flatMap(RTCSignalKind.init(rawValue:))
            else { return nil }
            return .signal(RTCSignalMessage(
                peer: from,
                peerRole: (object["from_role"] as? String).flatMap(RTCRole.init(rawValue:)),
                session: session,
                kind: kind,
                sdp: object["sdp"] as? String,
                candidate: object["candidate"] as? String,
                sdpMid: object["sdp_mid"] as? String,
                sdpMLineIndex: (object["sdp_mline_index"] as? NSNumber).map { $0.int32Value },
                reason: object["reason"] as? String
            ))
        case "rtc.error":
            return .error(code: object["code"] as? String ?? "unknown", session: object["session"] as? String, peer: object["to"] as? String)
        default:
            return nil
        }
    }

    private static func json(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}
