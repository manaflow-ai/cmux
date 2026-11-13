import CmuxScreenKit
import Foundation

extension MacScreenSession {
    public enum Phase: Equatable {
        case connecting
        case connected
        case failed(message: String, needsSignIn: Bool)
        case ended
    }

    public struct LiveStats: Equatable, Sendable {
        public var fps = 0.0
        public var kilobytesPerSecond = 0.0
        public var latencyMs: Double?
        public var encoding = "H.264"
        public var targetFps: Int?
        public var framesReceived: Double = 0
        public var framesDecoded: Double = 0
        public var framesDropped: Double = 0
    }

    /// Whether a `path.kind` of `cmux rd` is a relayed path (the hub's `path` signal says so).
    nonisolated static func isRelayed(_ kind: String) -> Bool {
        ["turn_relay", "do_relay", "via_cloud_region"].contains(kind)
    }

    static func pathLabel(_ kind: String?) -> String {
        switch kind {
        case "direct_lan": L.t("macScreen.rd.pathLan", "Direct (local network)")
        case "direct_wan": L.t("macScreen.rd.pathDirect", "Direct")
        case "turn_relay", "do_relay", "via_cloud_region": L.t("macScreen.rd.pathRelayed", "Relayed")
        default: "-"
        }
    }

    struct Answer: Encodable {
        var session: String
        var peerKey: String
        var stun: [String]
        var turn: [MacScreenRdServers.Turn]
        var candidates: [String]
        var socket: String
        var relayOnly: Bool

        enum CodingKeys: String, CodingKey {
            case session, stun, turn, candidates, socket
            case peerKey = "peer_key"
            case relayOnly = "relay_only"
        }
    }
}

extension VNCKeysym {
    /// The USB HID usage of this key (the inverse of `init?(hidUsage:)`): the Send Keys menu's chords
    /// go to a cmux.rd host as physical keys.
    nonisolated var hidUsage: UInt32? {
        (UInt32(0x07_0004) ... UInt32(0x07_00E7)).first { VNCKeysym(hidUsage: $0) == self }
    }
}
