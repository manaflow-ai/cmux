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

    /// Whether closing an agent session while it is mid-turn warns first.
    var warnsBeforeClosingAgentSession: Bool { get }
}

extension CloseTabWarningReading {
    /// Existing fakes and consumers default to the protected behavior while
    /// they adopt the separate agent-session setting.
    public var warnsBeforeClosingAgentSession: Bool { true }
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
        source: CloseTabCloseSource,
        isAgentSession: Bool = false
    ) -> CloseWarningKinds {
        var kinds: CloseWarningKinds = []
        if requiresConfirmation {
            if isAgentSession {
                if warnsBeforeClosingAgentSession { kinds.insert(.agentSession) }
            } else if warnsBeforeClosingTab {
                kinds.insert(.tab)
            }
        }
        // An active agent gets one agent-specific dialog. The ordinary
        // tab-close-button warning still applies to idle agents and every
        // non-agent tab, but must not stack another suppression choice onto
        // the agent warning.
        if !isAgentSession && source == .tabCloseButton && warnsBeforeClosingTabXButton {
            kinds.insert(.tabCloseButton)
        }
        return kinds
    }

    /// Whether closing should show a confirmation dialog, combining the
    /// caller's per-tab `requiresConfirmation` state with the warning
    /// toggles per ``CloseTabCloseSource``.
    public func shouldConfirmClose(
        requiresConfirmation: Bool,
        source: CloseTabCloseSource,
        isAgentSession: Bool = false
    ) -> Bool {
        !warningKinds(requiresConfirmation: requiresConfirmation, source: source, isAgentSession: isAgentSession).isEmpty
    }

    /// Whether a close should be gated by either the user's warning setting or
    /// an active process that must never be killed silently.
    public func shouldConfirmCloseIncludingSafety(
        requiresConfirmation: Bool,
        source: CloseTabCloseSource,
        isAgentSession: Bool = false
    ) -> Bool {
        (!isAgentSession && requiresConfirmation) || shouldConfirmClose(
            requiresConfirmation: requiresConfirmation,
            source: source,
            isAgentSession: isAgentSession
        )
    }

    public func warningKindsIncludingSafety(
        requiresConfirmation: Bool,
        source: CloseTabCloseSource,
        isAgentSession: Bool = false
    ) -> CloseWarningKinds {
        var kinds = warningKinds(
            requiresConfirmation: requiresConfirmation,
            source: source,
            isAgentSession: isAgentSession
        )
        if requiresConfirmation && !isAgentSession { kinds.insert(.safety) }
        return kinds
    }
}
