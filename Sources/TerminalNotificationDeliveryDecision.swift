/// Notification effects after shared focus and workspace-mute admission.
struct TerminalNotificationDeliveryDecision: Equatable, Sendable {
    let disposition: TerminalNotificationArrivalDisposition
    let effects: TerminalNotificationPolicyEffects

    static func resolve(
        isAppFocused: Bool,
        isActiveTab: Bool,
        isFocusedSurface: Bool,
        isMuted: Bool,
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

        var focusedEffects = effects
        // The active surface is already visible. Preserve history/unread and
        // the custom automation hook while suppressing external feedback.
        focusedEffects.desktop = false
        focusedEffects.sound = false
        focusedEffects.paneFlash = false
        return Self(disposition: .focusedInline, effects: focusedEffects)
    }
}
