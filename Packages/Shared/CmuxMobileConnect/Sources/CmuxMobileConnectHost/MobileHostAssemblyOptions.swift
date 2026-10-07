public import CmuxLink
public import CmuxLinkDirect
public import CmuxLinkWebRTC
public import CmuxLinkWG

/// Knobs of the Mac's acceptors. `wireGuardOverWebRTC` is the B3 DEV switch
/// (default off, like the phone's).
public struct MobileHostAssemblyOptions: Sendable {
    public var listen: DirectListenConfiguration
    public var webrtc: WebRTCConfiguration
    public var wireGuardOverWebRTC: Bool
    public var wireGuard: WireGuardLinkConfiguration
    public var link: LinkConfiguration

    public init(listen: DirectListenConfiguration = DirectListenConfiguration(),
                webrtc: WebRTCConfiguration = WebRTCConfiguration(), wireGuardOverWebRTC: Bool = false,
                wireGuard: WireGuardLinkConfiguration = WireGuardLinkConfiguration(),
                link: LinkConfiguration = LinkConfiguration()) {
        self.listen = listen
        self.webrtc = webrtc
        self.wireGuardOverWebRTC = wireGuardOverWebRTC
        self.wireGuard = wireGuard
        self.link = link
    }
}
