#if os(iOS)
import CmuxMobileShellModel

/// Stable owner of one provider/Mac model request.
struct TaskComposerModelRefreshID: Hashable {
    let provider: MobileTaskAgentProvider?
    let macPairingID: String
    let connectionIdentity: String?
}
#endif
