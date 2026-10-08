/// Which carrier pair a run drives.
public enum BenchRigKind: String, Sendable, CaseIterable, Codable {
    /// V1: libwebrtc data channels on loopback ICE.
    case v1 = "v1"
    /// V2: WireGuard lanes on B2's real WebRTC `wg` data channel (loopback ICE).
    case v2WebRTC = "v2-webrtc"
    /// V2: WireGuard lanes on the in-memory underlay (shapeable delay and loss).
    case v2Memory = "v2-mem"
    /// V3: Noise IK over TCP on 127.0.0.1.
    case v3 = "v3"
    /// A3's loopback carrier: no crypto, no sockets; the cost of `LinkSession` alone.
    case reference = "ref"

    var carrier: String {
        switch self {
        case .v1: "webrtc"
        case .v2WebRTC, .v2Memory: "webrtc-wg"
        case .v3: "direct"
        case .reference: "loopback"
        }
    }

    /// Whether the rig can inject delay and loss itself.
    var shapeable: Bool { self == .v2Memory || self == .reference }

    /// Whether the harness has a real alternate path for the roam workload.
    /// V3's local direct rig only owns one TCP endpoint; forcing `.turn` on it
    /// would create a synthetic relay result, so that workload is omitted
    /// until a split rig supplies a second authenticated direct endpoint.
    var supportsRoam: Bool { self != .v3 }
}
