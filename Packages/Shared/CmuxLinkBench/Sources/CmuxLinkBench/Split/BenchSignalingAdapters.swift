import CmuxLink
import CmuxLinkSignaling
import CmuxLinkWebRTC
import CmuxLinkWebRTCUnderlay
import CmuxLinkWG
import Foundation

/// The signaling and TURN seams needed by a split V1/V2 benchmark.
///
/// A production iOS caller passes B1's `ControlPlaneSignaling` here. Tests and
/// previews can pass the `InMemorySignalingHub` endpoint and a
/// `StaticICEServerProvider`. One router is deliberately created and retained
/// for both carriers: a signaling channel has one reader, while V1 and V2
/// sessions are demultiplexed by carrier and session id inside that router.
public struct BenchSignalingAdapters: Sendable {
    public let router: SignalRouter
    public let iceServers: any ICEServerProvider
    public let webrtcIdentity: any WebRTCIdentity
    public let wireGuardIdentity: WireGuardPrivateKey?
    public let wireGuardInstallID: String?
    public let webrtcConfiguration: WebRTCConfiguration
    public let wireGuardConfiguration: WireGuardLinkConfiguration

    public init(
        channel: any SignalingChannel,
        iceServers: any ICEServerProvider,
        webrtcIdentity: any WebRTCIdentity,
        wireGuardIdentity: WireGuardPrivateKey? = nil,
        wireGuardInstallID: String? = nil,
        webrtcConfiguration: WebRTCConfiguration = .init(),
        wireGuardConfiguration: WireGuardLinkConfiguration = .init()
    ) throws {
        if wireGuardIdentity != nil, wireGuardInstallID?.isEmpty != false {
            throw BenchSplitError.unauthorized("V2 signaling requires a non-empty install id")
        }
        router = SignalRouter(channel: channel)
        self.iceServers = iceServers
        self.webrtcIdentity = webrtcIdentity
        self.wireGuardIdentity = wireGuardIdentity
        self.wireGuardInstallID = wireGuardInstallID
        self.webrtcConfiguration = webrtcConfiguration
        self.wireGuardConfiguration = wireGuardConfiguration
    }

    /// Builds the selected carrier for one fixture. The caller may request
    /// both V1 and V2 in one `PathSelector`; each uses the same router and
    /// therefore the same control-plane reader.
    public func carriers(
        for descriptor: BenchServeDescriptor,
        selecting rig: BenchRigKind? = nil
    ) throws -> [any LinkCarrier] {
        try descriptor.validate()
        let requested = descriptor.carriers.map(CarrierKind.init(rawValue:))
        let selected: Set<CarrierKind>
        if let rig {
            let kind: CarrierKind
            switch rig {
            case .v1: kind = .webrtc
            case .v2WebRTC: kind = .webrtcWireGuard
            case .v2Memory, .v3, .reference:
                throw BenchSplitError.invalidDescriptor("unsupported split carrier selection")
            }
            guard requested.contains(kind) else {
                throw BenchSplitError.invalidDescriptor("carrier \(kind.rawValue) is not advertised")
            }
            selected = [kind]
        } else {
            selected = Set(requested.filter { $0 == .webrtc || $0 == .webrtcWireGuard })
        }

        var carriers: [any LinkCarrier] = []
        if selected.contains(.webrtc) {
            guard descriptor.webrtcHostKey.flatMap(WebRTCPublicKey.init(base64:)) != nil else {
                throw BenchSplitError.invalidDescriptor("webrtc host key")
            }
            let carrier = WebRTCCarrier(
                router: router,
                iceServers: iceServers,
                identity: webrtcIdentity,
                hostKeys: WebRTCHintsResolver(),
                configuration: webrtcConfiguration
            )
            carriers.append(carrier)
        }
        if selected.contains(.webrtcWireGuard) {
            guard let identity = wireGuardIdentity, let installID = wireGuardInstallID else {
                throw BenchSplitError.unauthorized("V2 benchmark has no device WireGuard identity")
            }
            guard descriptor.wireGuardHostKey.flatMap(WireGuardPublicKey.init(base64:)) != nil else {
                throw BenchSplitError.invalidDescriptor("wireguard host key")
            }
            let dialer = WebRTCDatagramDialer(
                router: router,
                iceServers: iceServers,
                configuration: webrtcConfiguration
            )
            carriers.append(WireGuardOverWebRTCCarrier(
                identity: identity,
                installID: installID,
                underlays: WebRTCUnderlayDialer(dialer: dialer),
                hostKeys: WireGuardHintsResolver(),
                configuration: wireGuardConfiguration
            ))
        }
        guard !carriers.isEmpty else {
            throw BenchSplitError.invalidDescriptor("no V1/V2 carrier selected")
        }
        return carriers
    }
}
