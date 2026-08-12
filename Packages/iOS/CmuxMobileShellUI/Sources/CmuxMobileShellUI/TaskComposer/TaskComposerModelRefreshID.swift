#if os(iOS)
import CmuxMobileShellModel

/// Identity that restarts model discovery when provider or selected Mac changes.
struct TaskComposerModelRefreshID: Hashable {
    let provider: MobileTaskAgentProvider?
    let macPairingID: String
}
#endif
