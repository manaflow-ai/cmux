#if os(iOS)
import CmuxMobileShellModel
import Foundation

/// The leave-relevant composer state, captured when a session opens and
/// compared when it closes. Model and effort picker VALUES are excluded
/// because catalog refreshes auto-reconcile them; deliberate picker taps are
/// tracked separately as an action flag so they still prompt on leave.
struct TaskComposerSessionFingerprint: Equatable {
    var prompt: String
    var workspaceName: String
    var templateID: MobileTaskTemplate.ID?
    var macPairingID: String
    var directory: String
    var didEditDirectory: Bool
    var workspaceGroupID: MobileWorkspaceGroupPreview.ID?
    var attachmentIDs: Set<UUID>
}
#endif
