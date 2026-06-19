public import Foundation

/// The window-side seam `WorkspaceCloseCoordinator` drives for the two close
/// responsibilities that cannot leave the app target: resolving the localized
/// confirmation strings (so `String(localized:)` binds to the app bundle, not
/// the package bundle, preserving non-English translations) and presenting the
/// confirmation `NSAlert` on the window. The per-window `TabManager` is the
/// single conformer.
///
/// **Why synchronous and not async.** The legacy `confirmClose` runs an
/// app-modal / sheet `NSAlert` that blocks the run loop and returns the user's
/// answer in the same MainActor turn; the batch-close loop relies on that
/// synchronous return to abort the whole batch when the user cancels a dialog
/// that is up. Turning `confirm` async would open a suspension window between
/// the decision and the next workspace teardown, observably changing the
/// batch-abort and re-entrancy contract. The decision flow inverts down here,
/// but the modal timing stays identical to the legacy closure.
@MainActor
public protocol CloseConfirming: AnyObject {
    /// The localized title for the multi-workspace / whole-window close
    /// confirmation (legacy `dialog.closeWorkspaces.title` /
    /// `dialog.closeWindow.title`).
    func closeWorkspacesTitle(willCloseWindow: Bool) -> String

    /// The localized message for the multi-workspace / whole-window close
    /// confirmation, given the count and the pre-bulleted, newline-joined
    /// workspace titles (legacy `dialog.closeWorkspaces.message` /
    /// `dialog.closeWorkspacesWindow.message`, fed through `String(format:)`).
    func closeWorkspacesMessage(
        willCloseWindow: Bool,
        workspaceCount: Int,
        bulletedTitles: String
    ) -> String

    /// The localized fallback display name for a workspace whose title is
    /// empty after whitespace/newline collapse (legacy
    /// `workspace.displayName.fallback`).
    var workspaceDisplayTitleFallback: String { get }

    /// Presents the close confirmation modally and returns whether the user
    /// confirmed. Mirrors the legacy `confirmClose(title:message:acceptCmdD:)`
    /// exactly: it self-gates the in-flight session, presents the shared cmux
    /// modal alert, and records the DEBUG UITest telemetry.
    func confirmClose(title: String, message: String, acceptCmdD: Bool) -> Bool
}
