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
    /// The warning toggles that make this close ask first; empty when it
    /// closes without a dialog. A dialog's "Don't ask again" checkbox turns
    /// off exactly these.
    ///
    /// Semantics are kept verbatim from the legacy
    /// `CloseTabConfirmationPolicy` namespace: the shortcut path warns only
    /// when the tab requires confirmation and the shortcut warning is
    /// enabled; the X-button path additionally warns whenever the X-button
    /// warning is enabled, regardless of the tab's state.
    public func warningKinds(
        requiresConfirmation: Bool,
        source: CloseTabCloseSource
    ) -> CloseWarningKinds {
        var kinds: CloseWarningKinds = []
        if requiresConfirmation && warnsBeforeClosingTab {
            kinds.insert(.tab)
        }
        if source == .tabCloseButton && warnsBeforeClosingTabXButton {
            kinds.insert(.tabCloseButton)
        }
        return kinds
    }

    /// Whether closing should show a confirmation dialog, combining the
    /// caller's per-tab `requiresConfirmation` state with the warning
    /// toggles per ``CloseTabCloseSource``.
    public func shouldConfirmClose(
        requiresConfirmation: Bool,
        source: CloseTabCloseSource
    ) -> Bool {
        !warningKinds(requiresConfirmation: requiresConfirmation, source: source).isEmpty
    }

    /// Whether a close should be gated by either the user's warning setting or
    /// an active process that must never be killed silently.
    public func shouldConfirmCloseIncludingSafety(
        requiresConfirmation: Bool,
        source: CloseTabCloseSource
    ) -> Bool {
        requiresConfirmation || shouldConfirmClose(
            requiresConfirmation: requiresConfirmation,
            source: source
        )
    }

    public func warningKindsIncludingSafety(
        requiresConfirmation: Bool,
        source: CloseTabCloseSource
    ) -> CloseWarningKinds {
        var kinds = warningKinds(requiresConfirmation: requiresConfirmation, source: source)
        if requiresConfirmation { kinds.insert(.safety) }
        return kinds
    }
}
