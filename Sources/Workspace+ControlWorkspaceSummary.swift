import CmuxControlSocket
import Foundation

extension Workspace {
    /// The Sendable ``ControlWorkspaceSummary`` snapshot of this workspace (the
    /// legacy `v2WorkspaceSummaryPayload` data, minus the index/selected/ref
    /// minting the ``ControlCommandCoordinator`` owns), bridging the app-typed
    /// `remoteStatusPayload()` through ``controlRemoteStatusJSON``.
    ///
    /// `workspace.list` / `workspace.current` build their payload rows from this
    /// summary; the value is byte-identical to the former inline
    /// `controlWorkspaceSummary(_:)` builder.
    var controlWorkspaceSummary: ControlWorkspaceSummary {
        ControlWorkspaceSummary(
            id: id, title: title, customTitle: customTitle,
            customDescription: customDescription,
            isPinned: isPinned,
            listeningPorts: listeningPorts,
            remoteStatus: controlRemoteStatusJSON,
            currentDirectory: currentDirectory,
            customColor: customColor,
            latestConversationMessage: latestConversationMessage,
            latestSubmittedMessage: latestSubmittedMessage,
            latestSubmittedAt: latestSubmittedAt.map(CmuxEventBus.isoTimestamp)
        )
    }
}
