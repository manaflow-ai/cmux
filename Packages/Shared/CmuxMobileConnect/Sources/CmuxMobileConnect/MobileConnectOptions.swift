public import CmuxLink
public import CmuxLinkWebRTC
public import CmuxLinkWG

/// Knobs of the phone's connection layer. `wireGuardOverWebRTC` is the B3
/// DEV switch (default off until D2 picks V1 or V2).
public struct MobileConnectOptions: Sendable {
    public var wireGuardOverWebRTC: Bool
    public var webrtc: WebRTCConfiguration
    public var wireGuard: WireGuardLinkConfiguration
    public var link: LinkConfiguration
    public var policy: PathPolicy

    public init(wireGuardOverWebRTC: Bool = false, webrtc: WebRTCConfiguration = WebRTCConfiguration(),
                wireGuard: WireGuardLinkConfiguration = WireGuardLinkConfiguration(),
                link: LinkConfiguration = LinkConfiguration(), policy: PathPolicy = PathPolicy()) {
        self.wireGuardOverWebRTC = wireGuardOverWebRTC
        self.webrtc = webrtc
        self.wireGuard = wireGuard
        self.link = link
        self.policy = policy
    }
}
