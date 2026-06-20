/// The originating gesture of a workspace-close request, which selects how the
/// confirmation decision combines the workspace's per-tab `requiresConfirmation`
/// state with the user's close-warning settings.
///
/// Lifted one-for-one from the legacy private `TabManager.CloseConfirmationSource`.
/// ``WorkspaceCloseCoordinator/shouldConfirmClose(requiresConfirmation:source:)``
/// maps each case onto the ``CloseTabWarningReading`` policy: a `.workspace`
/// close honours the caller's `requiresConfirmation` verbatim, a `.tabClose`
/// routes through the close-shortcut warning, and a `.tabCloseButton` routes
/// through the X-button warning.
public enum CloseConfirmationSource: Sendable, Equatable {
    /// A close initiated from the workspace itself (menu / Close Workspace
    /// shortcut). Confirmation is gated solely on the caller's
    /// `requiresConfirmation`.
    case workspace
    /// A close initiated by the tab-close gesture (Close Tab shortcut / batch
    /// sidebar close). Routes through the close-shortcut warning toggle.
    case tabClose
    /// A close initiated by the tab's X close button. Routes through the
    /// X-button warning toggle.
    case tabCloseButton
}
