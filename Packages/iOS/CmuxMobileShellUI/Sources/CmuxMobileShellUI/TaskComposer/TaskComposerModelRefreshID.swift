#if os(iOS)
import CmuxMobileShellModel

/// Identity that restarts model resolution when the provider, selected Mac, or
/// that Mac's advertised discovery capability changes.
struct TaskComposerModelRefreshID: Hashable {
    let provider: MobileTaskAgentProvider?
    let macPairingID: String
    let supportsHostDiscovery: Bool
}
#endif
