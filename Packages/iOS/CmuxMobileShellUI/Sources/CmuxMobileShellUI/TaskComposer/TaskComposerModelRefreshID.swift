#if os(iOS)
import CmuxMobileShellModel

/// Identity that restarts model resolution when the provider, selected Mac, or
/// live foreground connection changes.
struct TaskComposerModelRefreshID: Hashable {
    let provider: MobileTaskAgentProvider?
    let macPairingID: String
    let connectedMacPairingID: String?
}
#endif
