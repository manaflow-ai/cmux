extension NotificationSoundGate {
    /// What a notification is about and where it comes from, for its sound: its event (from its
    /// source and level), and the agent kind, workspace and groups whose rules apply.
    ///
    /// - Parameters:
    ///   - level: The daemon's level (`info`, `warning`, `error`); another value reads as `info`.
    ///   - source: Its source (``NotificationSource/init(wire:)``).
    ///   - agent: The notifying tab's agent (its chat's harness or the agent its hooks report), if any.
    ///   - workspace: The workspace id it belongs to, if any.
    /// - Returns: The arrival's ``NotificationPolicy/Arrival/soundEvent`` and ``NotificationPolicy/Arrival/soundScope``.
    public func classify(level: String, source: NotificationSource, agent: String?, workspace: String?)
        -> (NotificationSoundEvent, NotificationSoundScope) {
        var scope = NotificationSoundScope(agent: Self.agentKind(agent), workspace: workspace)
        if let workspace { scope.groups = groups(workspace) }
        return (NotificationSoundEvent(source: source, level: NotificationSoundEvent.Level(rawValue: level) ?? .info), scope)
    }

    /// An agent name as sound rules key it: lowercased, nil when empty.
    public nonisolated static func agentKind(_ raw: String?) -> String? {
        raw.flatMap { $0.isEmpty ? nil : $0.lowercased() }
    }

    /// A notification of a pane the person sees: under `notifications.sounds.when = always` it still
    /// sounds (no banner shows for it); otherwise nothing plays.
    public func playSeen(_ decision: NotificationPolicy.Decision, sounds: NotificationSoundPreferences) {
        guard sounds.when == .always else { return }
        play(decision, cooldownSeconds: sounds.cooldownSeconds, banner: false)
    }
}
