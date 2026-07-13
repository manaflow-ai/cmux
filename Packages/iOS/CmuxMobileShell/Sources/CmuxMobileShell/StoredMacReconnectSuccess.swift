import CMUXMobileCore
import CmuxMobilePairedMac
import CmuxMobileRPC
import CmuxMobileShellModel

struct StoredMacReconnectSuccess: Sendable {
    let client: MobileCoreRPCClient
    let ticket: CmxAttachTicket
    let route: CmxAttachRoute
    let workspaceResponse: MobileSyncWorkspaceListResponse
    let hostStatus: MobileHostStatusResponse?
    let resolvedInstanceTag: String?
    let sourceMacDeviceID: String
    let sourceMac: MobilePairedMac
    let scope: MobileShellScopeSnapshot
    let displayName: String
    let persistsPairedMac: Bool
}
