public import CmuxLink
public import CmuxLinkWebRTC
public import CmuxLinkWG

/// The transport the phone is allowed to use for a mobile link.
///
/// `.automatic` preserves the normal reachability policy. The forced modes
/// are DEV controls for testing a particular live carrier against a Mac.
public enum MobileTransportPreference: String, CaseIterable, Codable, Equatable, Sendable {
    case automatic
    case direct
    case webrtc
}

/// Knobs of the phone's connection layer. `transport` is a DEV override for
/// carrier selection; `wireGuardOverWebRTC` is the B3 DEV switch (default off
/// until D2 picks V1 or V2).
public struct MobileConnectOptions: Sendable {
    public var transport: MobileTransportPreference
    public var wireGuardOverWebRTC: Bool
    public var webrtc: WebRTCConfiguration
    public var wireGuard: WireGuardLinkConfiguration
    public var link: LinkConfiguration
    public var policy: PathPolicy

    public init(transport: MobileTransportPreference = .automatic, wireGuardOverWebRTC: Bool = false,
                webrtc: WebRTCConfiguration = WebRTCConfiguration(),
                wireGuard: WireGuardLinkConfiguration = WireGuardLinkConfiguration(),
                link: LinkConfiguration = LinkConfiguration(), policy: PathPolicy = PathPolicy()) {
        self.transport = transport
        self.wireGuardOverWebRTC = wireGuardOverWebRTC
        self.webrtc = webrtc
        self.wireGuard = wireGuard
        self.link = link
        self.policy = policy
    }
}
