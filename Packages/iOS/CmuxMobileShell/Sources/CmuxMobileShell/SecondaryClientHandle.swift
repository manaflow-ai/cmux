import CMUXMobileCore
import CmuxMobileRPC
import CmuxMobileShellModel

/// The live client to a secondary Mac plus the route/ticket it was dialed on.
struct SecondaryClientHandle {
    let client: MobileCoreRPCClient
    let route: CmxAttachRoute
    let ticket: CmxAttachTicket
    /// Authority expected by the paired row when this client was established.
    let storedInstanceTag: String?
    /// Instance identity proven by this client's authenticated host status.
    let authenticatedInstanceTag: String?
    let supportedHostCapabilities: Set<String>
    let actionCapabilities: MobileWorkspaceActionCapabilities
}
