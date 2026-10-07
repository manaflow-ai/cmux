/// Which carrier implementation produced a transport. Open so that test and
/// future carriers name themselves without a change here.
public struct CarrierKind: RawRepresentable, Sendable, Hashable, Codable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue }

    /// V1: WebRTC P2P with TURN fallback, signaling over the control plane.
    public static let webrtc = CarrierKind(rawValue: "webrtc")
    /// V2: WebRTC carried over the in-app userspace WireGuard overlay.
    public static let webrtcWireGuard = CarrierKind(rawValue: "webrtc-wg")
    /// V3: a direct address pinned to the host's device key.
    public static let direct = CarrierKind(rawValue: "direct")
    /// The host's Durable Object relay.
    public static let doRelay = CarrierKind(rawValue: "do-relay")
}
