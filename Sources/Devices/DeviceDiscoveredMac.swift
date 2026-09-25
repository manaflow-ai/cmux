import CMUXMobileCore
import CmuxIrohTransport

/// Presentation fields for a Mac already authorized by the v2 directory.
struct DeviceDiscoveredMac: Sendable {
    let bindingID: String
    let deviceID: String
    let tag: String
    let displayName: String?
    let endpointID: CmxIrohPeerIdentity
    let pathHints: [CmxIrohPathHint]
    /// Whether the directory that named this Mac was issued by a service that
    /// implements the Mac-to-Mac admission rule; false means no dial can be admitted.
    let controlPlaneSupportsMacPeers: Bool
}
