// Notification sounds per event and level (plans/cmux-next/notifications.md, "Sounds"). Bound by
// CmuxNextSettings' NotificationSoundActions. Titles live in Localizable.xcstrings.

nonisolated enum NotificationSoundActionCatalog: ActionCatalogGroup {
    static func descriptors() -> [ActionDescriptor] {
        let keywords = ["sound", "chime", "alert", "audio", "mute", "volume", "notifications"]
        return [
            ActionDescriptor(
                id: "notifications.setWorkspaceSound", title: t("action.notifications.setWorkspaceSound", "Notification Sound for Workspace"),
                keywords: keywords + ["workspace"], category: .notifications, symbol: "speaker.wave.2",
                surfaces: [.palette, .contextMenu], arguments: [soundChoice, eventChoice, volumeChoice, fileChoice], targets: [.workspace],
                cliName: "notification set-workspace-sound"
            ),
            ActionDescriptor(
                id: "notifications.setGroupSound", title: t("action.notifications.setGroupSound", "Notification Sound for Group"),
                keywords: keywords + ["group", "section"], category: .notifications, symbol: "speaker.wave.2",
                surfaces: [.palette, .contextMenu], arguments: [soundChoice, eventChoice, volumeChoice, fileChoice], targets: [.workspaceGroup],
                cliName: "notification set-group-sound"
            ),
            ActionDescriptor(
                id: "notifications.setAgentSound", title: t("action.notifications.setAgentSound", "Notification Sound for Agent…"),
                keywords: keywords + ["agent", "claude", "codex", "harness"], category: .notifications, symbol: "speaker.wave.2",
                surfaces: [.palette], arguments: [agentChoice, soundChoice, eventChoice, volumeChoice, fileChoice],
                cliName: "notification set-agent-sound"
            ),
            ActionDescriptor(
                id: "notifications.setEventSound", title: t("action.notifications.setEventSound", "Notification Sound for Event…"),
                keywords: keywords + ["event", "finished", "needs input", "permission", "error", "bell"], category: .notifications,
                symbol: "speaker.wave.2", surfaces: [.palette], arguments: [eventOnlyChoice, soundChoice, fileChoice],
                cliName: "notification set-event-sound"
            ),
            ActionDescriptor(
                id: "notifications.previewSound", title: t("action.notifications.previewSound", "Preview Notification Sound"),
                keywords: keywords + ["preview", "test", "play", "hear"], category: .notifications, symbol: "play.circle",
                surfaces: [.palette, .contextMenu], arguments: [eventChoice], targets: [.workspace],
                cliName: "notification preview-sound"
            ),
            ActionDescriptor(
                id: "notifications.importSound", title: t("action.notifications.importSound", "Import Notification Sound…"),
                keywords: keywords + ["import", "custom", "file", "own"], category: .notifications, symbol: "square.and.arrow.down",
                surfaces: [.palette], arguments: [fileChoice], cliName: "notification import-sound"
            ),
        ]
    }

    /// The sound a level plays: inherit, none, the banner's default, a built-in sound, or a file
    /// to import (`choose` opens a picker). The palette lists every installed sound too.
    static var soundChoice: ActionArgument {
        ActionArgument(name: "sound", title: t("argument.notifications.sound", "Sound"), kind: .string, isRequired: false,
                       suggestions: ActionSuggestions(source: ActionSuggestions.notificationSounds, pinned: [
                           ActionEnumCase(value: "inherit", title: t("argument.value.notifications.sound.inherit", "Inherit")),
                           ActionEnumCase(value: "none", title: t("argument.value.notifications.sound.none", "No Sound")),
                           ActionEnumCase(value: "default", title: t("argument.value.notifications.sound.default", "macOS Default")),
                       ] + builtInSounds.map { ActionEnumCase(value: $0, title: $0) } + [
                           ActionEnumCase(value: "choose", title: t("argument.value.notifications.sound.choose", "Choose Sound File…")),
                       ]))
    }

    /// The macOS sounds every Mac has (`/System/Library/Sounds`), by their own names.
    static let builtInSounds = ["Basso", "Blow", "Bottle", "Frog", "Funk", "Glass", "Hero", "Morse", "Ping", "Pop", "Purr",
                                "Sosumi", "Submarine", "Tink"]

    /// Which event the sound is for; `all` (the default) sets the level's sound for every event.
    static var eventChoice: ActionArgument {
        ActionArgument(name: "event", title: t("argument.notifications.event", "Event"),
                       kind: .enumeration([ActionEnumCase(value: "all", title: t("argument.value.notifications.event.all", "Every Event"))] + eventCases),
                       isRequired: false)
    }

    /// One event (the global per-event sound).
    static var eventOnlyChoice: ActionArgument {
        ActionArgument(name: "event", title: t("argument.notifications.event", "Event"), kind: .enumeration(eventCases))
    }

    static var eventCases: [ActionEnumCase] {
        [
            ActionEnumCase(value: "finished", title: t("argument.value.notifications.event.finished", "Agent Finished")),
            ActionEnumCase(value: "needsInput", title: t("argument.value.notifications.event.needsInput", "Agent Needs Input")),
            ActionEnumCase(value: "error", title: t("argument.value.notifications.event.error", "Error")),
            ActionEnumCase(value: "bell", title: t("argument.value.notifications.event.bell", "Terminal Notification")),
            ActionEnumCase(value: "message", title: t("argument.value.notifications.event.message", "cmux notify Message")),
        ]
    }

    /// 0 to 100 % of the master volume; absent keeps the level's volume.
    static var volumeChoice: ActionArgument {
        ActionArgument(name: "volume", title: t("argument.notifications.volume", "Volume (%)"), kind: .int(0...100), isRequired: false)
    }

    /// A sound file to import into ~/Library/Sounds and use (CLI: `--arg file=~/Downloads/chime.wav`).
    static var fileChoice: ActionArgument {
        ActionArgument(name: "file", title: t("argument.notifications.file", "Sound File"), kind: .string, isRequired: false)
    }

    /// The agent kind (`claude`, `codex`, …) as its hooks or its chat name it.
    static var agentChoice: ActionArgument {
        ActionArgument(name: "agent", title: t("argument.notifications.agent", "Agent"), kind: .string,
                       suggestions: ActionSuggestions(source: ActionSuggestions.notificationAgents, pinned: [
                           ActionEnumCase(value: "claude", title: "Claude Code"),
                           ActionEnumCase(value: "codex", title: "Codex"),
                           ActionEnumCase(value: "opencode", title: "OpenCode"),
                           ActionEnumCase(value: "gemini", title: "Gemini"),
                       ]))
    }

    private static func t(_ key: StaticString, _ english: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: english, bundle: .module)
    }
}
