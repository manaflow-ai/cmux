internal import CmuxMobileShellModel

/// Device/provider identity for the composer's in-memory discovered-model cache.
struct MobileTaskModelCacheKey: Hashable {
    let macDeviceID: String
    let instanceTag: String?
    let provider: MobileTaskAgentProvider
}
