#if os(iOS)
import CmuxMobileShellModel

/// Stable owner of one provider/Mac model request.
struct TaskComposerModelRefreshID: Hashable {
    let provider: MobileTaskAgentProvider?
    let macPairingID: String
}

/// Observable inputs that can make the stable request owner runnable.
///
/// A foreground connection transition must restart discovery immediately, but
/// it does not change which provider/Mac owns the eventual result.
struct TaskComposerModelRefreshTrigger: Hashable {
    let requestID: TaskComposerModelRefreshID
    let connectedMacPairingID: String?
}
#endif
