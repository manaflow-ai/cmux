/// The window-side seam ``WorkspaceCloseCoordinator`` drives for the two
/// confirmation responsibilities that cannot leave the app target: resolving the
/// localized confirmation strings (so `String(localized:)` binds to the app
/// bundle, not the package bundle, preserving non-English translations) and
/// presenting the confirmation `NSAlert` on the window. The per-window
/// `TabManager` is the single conformer.
///
/// **What moved down and what stays here.** The coordinator now owns the WHOLE
/// confirmation decision: the re-entrancy session flag (`closeConfirmationInFlight`),
/// the test-override handler, the suppression-flag read/write
/// (`workspaceGroups.anchorCloseSuppressed`), the which-dialog / which-message
/// choice, and the `String(format:)` assembly. The witness only (a) returns the
/// localized string pieces and (b) builds + runs the `NSAlert` via the shared
/// `runCmuxModalAlert` presenter, reporting the ``CloseConfirmationOutcome``.
///
/// **Why synchronous and not async.** The legacy `confirmClose` runs an
/// app-modal / sheet `NSAlert` that blocks the run loop and returns the user's
/// answer in the same MainActor turn; the batch-close loop relies on that
/// synchronous return to abort the whole batch when the user cancels a dialog
/// that is up. Turning `present` async would open a suspension window between
/// the decision and the next workspace teardown, observably changing the
/// batch-abort and re-entrancy contract. The decision flow inverts down to the
/// coordinator, but the modal timing stays identical to the legacy closure.
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

    /// The localized title for the single-workspace close confirmation (legacy
    /// `dialog.closeWorkspace.title`).
    var closeWorkspaceTitle: String { get }

    /// The localized message for the single-workspace close confirmation (legacy
    /// `dialog.closeWorkspace.message`).
    var closeWorkspaceMessage: String { get }

    /// The localized title for the pinned-workspace close confirmation (legacy
    /// `dialog.closePinnedWorkspace.title`).
    var closePinnedWorkspaceTitle: String { get }

    /// The localized message for the pinned-workspace close confirmation (legacy
    /// `dialog.closePinnedWorkspace.message`).
    var closePinnedWorkspaceMessage: String { get }

    /// The localized title for the group-anchor close confirmation (legacy
    /// `dialog.closeAnchor.title`).
    var closeAnchorTitle: String { get }

    /// The localized `String(format:)` template for the anchor-close message
    /// when the group has no other members (legacy
    /// `dialog.closeAnchor.message.lone`, one `%@` group-name slot).
    var closeAnchorMessageLoneFormat: String { get }

    /// The localized `String(format:)` template for the anchor-close message
    /// when the group has exactly one other member (legacy
    /// `dialog.closeAnchor.message.one`, one `%@` group-name slot).
    var closeAnchorMessageOneFormat: String { get }

    /// The localized `String(format:)` template for the anchor-close message
    /// when the group has two or more other members (legacy
    /// `dialog.closeAnchor.message.many`, a `%1$@` group-name slot and a
    /// `%2$lld` member-count slot).
    var closeAnchorMessageManyFormat: String { get }

    /// Builds and presents `prompt` modally and reports the outcome. Mirrors the
    /// legacy `confirmClose` / `confirmAnchorWorkspaceClose` alert construction
    /// exactly: it constructs the `NSAlert` (Close / Cancel buttons, optional
    /// "Don't ask again" checkbox), runs it through the shared cmux modal
    /// presenter, and records the DEBUG UITest telemetry. The coordinator has
    /// already taken the in-flight session and made the whole decision; this is
    /// purely AppKit presentation.
    func present(_ prompt: CloseConfirmationPrompt) -> CloseConfirmationOutcome
}
