import CmuxNextActions
import CmuxNextDaemon
import CmuxNextDesign
import Foundation

/// A `cmux://workspace/ws_…` link to a workspace that is not open (cmux#25572: a Chief's
/// reply links the workspaces it names, and the person clicks one after closing it): the
/// daemon that still holds the workspace in its closed history reopens it, as Reopen Closed
/// Workspace would, and the link reveals it. It reopens as a new workspace (a new `ws_` id;
/// keeping the id is the durable-links a343 slice). No daemon holding it is the gone refusal.
@MainActor
enum DurableWorkspaceLink {
    /// Reopens closed workspace `id` and reveals it: `link.open`'s path for a workspace link
    /// whose workspace is not open (``DeepLinkNavigator``). The failure, if any, is the
    /// tracked work's result.
    static func open(_ id: String, intent: WindowActivation.Intent, services: AppServices) {
        let daemons = services.machines.daemons.filter { $0.connection != nil }
        services.registry.track(Task { @MainActor () -> ActionWorkFailure? in
            var failure: String?
            var reopened: (daemon: DaemonService, workspace: ResourceID?)?
            let outcome = await DurableTabLink.reopen(on: daemons.indices.map { $0 }) { index in
                let daemon = daemons[index]
                guard let connection = daemon.connection else { return .notInHistory }
                do {
                    let item = try await connection.state.reopenClosed(workspace: id)
                    await daemon.appliedThroughReply(on: connection, after: "reopen linked workspace")
                    reopened = (daemon, item.workspaceID)
                    return .reopened
                } catch DaemonError.command(_, _, let code, _, _) where code == "resource.not_found" {
                    return .notInHistory
                } catch {
                    daemon.logger.error("closed.reopen {workspace} failed: \(String(describing: error), privacy: .public)")
                    failure = "closed.reopen: \(error)"
                    throw error
                }
            }
            switch outcome {
            case .reopened:
                if let reopened, let workspace = reopened.workspace,
                   let key = await reopened.daemon.store.workspace(afterReopen: workspace, clock: reopened.daemon.reopenClock),
                   let window = services.windows.reveal(workspaceID: key)?.window {
                    services.showJumpWindow(window, intent)
                    return nil
                }
                return ActionWorkFailure(RefusalStrings.linkTargetGone, mayHaveApplied: true)
            case .gone:
                services.registry.refuse(RefusalStrings.linkTargetGone)
                return ActionWorkFailure(refusal: .unavailable, reason: RefusalStrings.linkTargetGone)
            case .failed:
                return ActionWorkFailure(failure ?? RefusalStrings.linkTargetGone, mayHaveApplied: true)
            }
        })
    }
}
