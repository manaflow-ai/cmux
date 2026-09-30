import CmuxFoundation
import CmuxRemoteSession
import Foundation

/// `workspace.remote.pty_bridge` answers for a remote session that gave up
/// (https://github.com/manaflow-ai/cmux/issues/12813).
///
/// The reply carries the structured ``SSHPTYAttachExitCode/sessionParkedErrorCode``
/// and, as its message, the same app-localized detail the sidebar shows. The
/// attach wrapper keys off the code, stops retrying, and prints the detail, so
/// the message is deliberately not passed through the PTY error sanitizer.
extension TerminalController {
    /// The parked reply for a workspace that has no controller and will not
    /// get one until the user reconnects; `nil` while a controller exists or
    /// may still be created.
    nonisolated func v2RemoteSessionParkedResult(
        workspaceId: UUID,
        params: [String: Any]
    ) -> V2CallResult? {
        v2MainSync {
            let workspace = v2ResolveTabManager(params: params)?
                .tabs.first(where: { $0.id == workspaceId })
                ?? AppDelegate.shared?.tabManagerFor(tabId: workspaceId)?
                .tabs.first(where: { $0.id == workspaceId })
            guard let detail = workspace?.remoteSessionParkedDetailWithoutController else {
                return nil
            }
            return v2RemoteSessionParkedResult(
                detail: detail,
                workspaceId: workspaceId,
                workspaceRef: v2Ref(kind: .workspace, uuid: workspaceId)
            )
        }
    }

    /// The parked reply for a controller that reported
    /// ``RemoteSessionParkedError`` to a bridge start.
    nonisolated func v2RemoteSessionParkedResult(
        detail: String,
        workspaceId: UUID,
        workspaceRef: Any
    ) -> V2CallResult {
        .err(code: SSHPTYAttachExitCode.sessionParkedErrorCode, message: detail, data: [
            "workspace_id": workspaceId.uuidString,
            "workspace_ref": workspaceRef,
        ])
    }
}
