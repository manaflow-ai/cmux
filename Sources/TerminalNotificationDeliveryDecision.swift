/// Notification effects after shared focus and workspace-mute admission.
struct TerminalNotificationDeliveryDecision: Equatable, Sendable {
    let disposition: TerminalNotificationArrivalDisposition
    let effects: TerminalNotificationPolicyEffects

    static func resolve(
        isAppFocused: Bool,
        isActiveTab: Bool,
        isFocusedSurface: Bool,
        isMuted: Bool,
        soundWhenFocused: Bool,
        effects: TerminalNotificationPolicyEffects,
        suppressWhenAppFocused: Bool = false
    ) -> Self {
        if isMuted {
            // A workspace mute drops every effect before history, badges,
            // phone forwarding, commands, or UI delivery can observe it.
            return Self(disposition: .muted, effects: .allSuppressed)
        }

        guard isAppFocused, isActiveTab, isFocusedSurface else {
            if isAppFocused, suppressWhenAppFocused {
                // `notifications.suppressWhenAppFocused`: cmux is the active
                // app, so skip the banner but keep the sound, pane flash,
                // and custom command for this arrival.
                var appFocusedEffects = effects
                appFocusedEffects.desktop = false
                return Self(disposition: .focusedInline, effects: appFocusedEffects)
            }
            return Self(disposition: .externalDelivery, effects: effects)
        }

        var focusedEffects = effects.keepingFocusedWorkspaceInPlace(isFocusedPane: true)
        // The active surface is already visible. Preserve history/unread and
        // the custom automation hook while suppressing external feedback.
        focusedEffects.desktop = false
        focusedEffects.paneFlash = false
        focusedEffects = focusedEffects.keepingFocusedPaneQuiet(soundWhenFocused: soundWhenFocused)
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

    /// The pane the user is looking at already shows its ring, so it plays no
    /// sound unless `notifications.soundWhenFocused` opts in. The "default"
    /// sound is the system alert, which reads as an error. Both the terminal
    /// notification store and Feed's delivery lane apply this.
    func keepingFocusedPaneQuiet(soundWhenFocused: Bool) -> Self {
        var effects = self
        effects.sound = effects.sound && soundWhenFocused
        return effects
    }
}
