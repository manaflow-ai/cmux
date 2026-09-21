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
}
