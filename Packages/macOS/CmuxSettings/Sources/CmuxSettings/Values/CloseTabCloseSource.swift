import Foundation

/// How a tab close was initiated, for
/// ``CloseTabWarningReading/shouldConfirmClose(requiresConfirmation:source:)``.
///
/// The two sources consult different warning toggles: the close shortcut
/// only warns for tabs that require confirmation, while the tab's X button
/// can additionally warn unconditionally.
public enum CloseTabCloseSource: Sendable, Equatable {
    /// The close-tab keyboard shortcut (or an equivalent menu/palette action).
    case shortcut

    /// The tab's inline close (X) button.
    case tabCloseButton
}
