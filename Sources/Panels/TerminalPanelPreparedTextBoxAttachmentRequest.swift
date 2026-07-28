import CmuxRemoteSession
import Foundation

struct TerminalPanelPreparedTextBoxAttachmentRequest {
    let id: UUID
    let fileURL: URL
    let workspaceRemoteController: RemoteSessionCoordinator?
    let remoteUploader: TerminalPanel.TextBoxAttachmentRemoteUploader?
    let budget: TextBoxAttachmentPreparationBudget
    /// Structured route resolved once while the request is admitted.
    let resolvedTarget: TerminalImageTransferTarget?
    var phase: TerminalPanelPreparedTextBoxAttachmentPhase
    var preparationPermit: TextBoxAttachmentPreparationBudget.Permit?
    var preparationTask: Task<Void, Never>?
    var deadlineTask: Task<Void, Never>?
    var placeholderWasInserted: Bool
    var completions: [@MainActor (Bool) -> Void]
}
