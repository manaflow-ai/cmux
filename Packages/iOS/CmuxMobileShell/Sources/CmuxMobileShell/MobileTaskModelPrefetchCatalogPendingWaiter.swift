internal import CmuxMobileShellModel

struct MobileTaskModelPrefetchCatalogPendingWaiter {
    let provider: MobileTaskAgentProvider
    let continuation: CheckedContinuation<MobileTaskModelListResult?, Never>
}
