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
        /// The host's own once-a-second counters (cmux.rd/1 `stats`), nil until the first one or from a host that
        /// sends none: the rate it streams at, the share of packets it resent or lost, its median encode time.
        public var hostKbps: Double?
        public var lossPercent: Double?
        public var encodeMsP50: Double?
        /// The profile the host says it encodes with (`standard`, `ultra`); nil from a host too old to say. The view
        /// labels Ultra only from this, never from the quality it asked for.
        public var encodeProfile: String?
    }

    /// Why the last session failed, in the words of the side that knew. The failed card says
    /// it (``MacScreenPaneModel/failedDetail``); nil when nobody said, and the card falls back.
    public enum FailureCause: Equatable, Sendable {
        /// The host could not serve the session: its own cmux.rd/1 `ended` (`failed: <reason>`;
        /// capture, encoder or helper trouble on that Mac). `reason` may be empty.
        case host(String)
        /// This Mac's link to the host failed (`cmux rd connect`'s words: no route, a timeout).
        case link(String)
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
        var peerCarrier: String?

        enum CodingKeys: String, CodingKey {
            case session, stun, turn, candidates, socket
            case peerCarrier = "peer_carrier"
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
