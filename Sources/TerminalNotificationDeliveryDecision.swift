/// Notification effects after shared focus and workspace-mute admission.
struct TerminalNotificationDeliveryDecision: Equatable, Sendable {
    let disposition: TerminalNotificationArrivalDisposition
    let effects: TerminalNotificationPolicyEffects

    static func resolve(
        isAppFocused: Bool,
        isActiveTab: Bool,
        isFocusedSurface: Bool,
        isMuted: Bool,
        effects: TerminalNotificationPolicyEffects
    ) -> Self {
        if isMuted {
            // A workspace mute drops every effect before history, badges,
            // phone forwarding, commands, or UI delivery can observe it.
            return Self(disposition: .muted, effects: .allSuppressed)
        }

        guard isAppFocused, isActiveTab, isFocusedSurface else {
            return Self(disposition: .externalDelivery, effects: effects)
        }

        var focusedEffects = effects.keepingFocusedWorkspaceInPlace(isFocusedPane: true)
        // The active surface is already visible. Preserve history/unread and
        // the custom automation hook while suppressing external feedback.
        focusedEffects.desktop = false
        focusedEffects.sound = false
        focusedEffects.paneFlash = false
        return Self(disposition: .focusedInline, effects: focusedEffects)
    }
}

extension TerminalNotificationPolicyEffects {
    /// A notification for the pane the user is looking at must not move the
    /// workspace they are typing in. Both the terminal notification store and
    /// Feed's delivery lane apply this before sidebar ordering.
    func keepingFocusedWorkspaceInPlace(isFocusedPane: Bool) -> Self {
        guard isFocusedPane else { return self }
        var effects = self
        effects.reorderWorkspace = false
        return effects
    }
}
