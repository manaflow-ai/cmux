import CMUXMobileCore
import CmuxMobilePairedMac

struct StoredMacReconnectPersistenceRequest {
    let ticket: CmxAttachTicket
    let sourceMacDeviceID: String
    let storedAuthorityMac: MobilePairedMac?
    let displayName: String?
    let reportedInstanceTag: String?
    let resolvedInstanceTag: String?
}
