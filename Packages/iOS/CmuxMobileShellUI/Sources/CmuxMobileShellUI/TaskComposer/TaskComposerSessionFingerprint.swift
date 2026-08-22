#if os(iOS)
import CmuxMobileShellModel
import Foundation

/// The leave-relevant composer state, captured when a session opens and
/// compared when it closes. Model and effort picker choices are deliberately
/// excluded: changing only those never prompts to save a draft.
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
