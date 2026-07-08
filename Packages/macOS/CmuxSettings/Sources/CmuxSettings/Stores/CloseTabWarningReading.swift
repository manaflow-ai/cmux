import Foundation

/// Read access to the close-tab warning settings.
///
/// Consumer domains (workspace close flows, tab chrome) depend on this seam
/// instead of the concrete ``CloseTabWarningStore`` so they can be tested
/// with a fixed fake and never name the storage mechanism.
public protocol CloseTabWarningReading: Sendable {
    /// Whether closing a tab via the close shortcut warns first when the tab
    /// requires confirmation.
    var warnsBeforeClosingTab: Bool { get }

    /// Whether closing a tab via its X button always warns first.
    var warnsBeforeClosingTabXButton: Bool { get }

    /// Whether the tab close (X) button is hidden entirely.
    var hidesTabCloseButton: Bool { get }
}

extension CloseTabWarningReading {
    /// Whether closing should show a confirmation dialog, combining the
    /// caller's per-tab `requiresConfirmation` state with the warning
    /// toggles per ``CloseTabCloseSource``.
    ///
    /// Semantics are kept verbatim from the legacy
    /// `CloseTabConfirmationPolicy` namespace: the shortcut path warns only
    /// when the tab requires confirmation and the shortcut warning is
    /// enabled; the X-button path additionally warns whenever the X-button
    /// warning is enabled, regardless of the tab's state.
    public func shouldConfirmClose(
        requiresConfirmation: Bool,
        source: CloseTabCloseSource
    ) -> Bool {
        switch source {
        case .shortcut:
            return requiresConfirmation && warnsBeforeClosingTab
        case .tabCloseButton:
            return warnsBeforeClosingTabXButton
                || (requiresConfirmation && warnsBeforeClosingTab)
        }
    }
}
