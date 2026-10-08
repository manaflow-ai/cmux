import Foundation

/// The dispatcher commands the app sends the page: Continue in, Create checkpoint and the
/// grouped-permission actions.
extension AgentPaneView {
    /// Opens the frontend's Continue in… chooser. The chooser owns target
    /// selection and preparation; native actions do not create a second
    /// handoff pipeline.
    public func showContinueIn() {
        deliver([.command("continueIn")], scripts: ["window.cmuxAcpmuxBridge?.command?.(\"continueIn\");"])
    }
    /// Palette and page buttons enter the same inline checkpoint review.
    public func showCreateCheckpoint() {
        guard model.checkpointAvailable else { return }
        deliver([.command("createCheckpoint")], scripts: ["window.cmuxAcpmuxBridge?.command?.(\"createCheckpoint\");"])
    }

    /// Runs a grouped-permission action from the app shortcut registry. The
    /// page keeps the decision scoped to its selected session and refuses
    /// stale, collecting, or unavailable groups before sending anything.
    public func runPermissionAction(_ command: String) {
        let allowed = ["permissionAllowOnce", "permissionAllowChat", "permissionDeny", "permissionExpand",
                       "permissionRetry", "permissionRevoke", "permissionRefresh"]
        guard allowed.contains(command) else { return }
        // The user pressed the app's permission shortcut: that is the gesture its answer uses.
        model.transport.gestures.record()
        deliver([.command(command)], scripts: ["window.cmuxAcpmuxBridge?.command?.(\"\(command)\");"])
    }
}
