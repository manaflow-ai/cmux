import Foundation

/// The live-workspace seam ``RemoteTmuxMirrorCoordinator`` reaches back through
/// for the one workspace-side decision its pane-close orchestration cannot make
/// on its own: presenting the kill-pane confirmation modal.
///
/// Resolving the owning tab manager, building the localized dialog copy, and
/// running the modal all stay in the app target (they touch AppKit and the
/// workspace's tab-manager graph), so the coordinator forwards the single
/// already-classified active-command string and receives the user's decision.
///
/// This mirrors the ``RemoteSurfaceHosting`` seam: every method lifted into the
/// coordinator was a plain `@MainActor` method on the `@MainActor` workspace, so
/// the seam is `@MainActor`, the coordinator is `@MainActor`, and the app target
/// conforms the workspace directly with no bridging adapter. The coordinator
/// references the host weakly (the workspace owns the coordinator), so there is
/// no retain cycle.
@MainActor
public protocol RemoteTmuxMirrorHosting: AnyObject {
    /// Presents the kill-pane close confirmation and returns `true` to proceed
    /// with the kill, `false` to refuse it (the user declined, or no tab manager
    /// is available to ask).
    ///
    /// - Parameter activeCommand: the foreground command name when the pane is
    ///   running an active command (used to name it in the dialog), or `nil` to
    ///   use the generic close-tab message.
    func presentRemoteTmuxPaneCloseConfirmation(activeCommand: String?) -> Bool
}
