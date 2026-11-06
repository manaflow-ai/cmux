/// Settings > Chief > Subagents: whether the Chief may route each subagent to the harness best at its task
/// (`spawn(harness)`: Codex for long coding, Claude for writing and UI), whatever harness the Chief itself
/// runs on (Leo 2026-11-01: "maybe toggle off-able but if you look into grokbot they auto route stuff all the
/// time"). Off by default (Leo 2026-11-01: "optional ofc we don't wanna change defaults or whatnot yet"); a Chief's
/// own `chief engine set --subagent-routing auto|off` wins over it. The Chief host reads the key at each spawn,
/// so a change applies at once.
nonisolated enum ChiefRoutingSettingsSchema {
    static let autoRoutePath = ["chief", "autoRouteSubagents"]
    /// Each subagent gets its own sidebar workspace when it starts. The Chief host reads the key at each spawn
    /// (optchat-chief `brain/subagent_settings.rs`); unset, the Chief's own `chief settings` value applies.
    static let showWorkspacesPath = ["subagents", "showWorkspaces"]
    /// A finished subagent's workspace closes, for fewer workspaces in the sidebar. Off by default: a subagent's
    /// workspace never closes by itself, only when the person closes it (Aziz 2026-11-05: "why are your agents
    /// disappearing from sidebar?"). The Chief host reads the key when a subagent finishes.
    static let closeFinishedPath = ["subagents", "closeFinishedWorkspaces"]
    static let keys: Set<String> = [autoRoutePath, showWorkspacesPath, closeFinishedPath]
        .map { $0.joined(separator: ".") }
        .reduce(into: Set<String>()) { $0.insert($1) }

    static var descriptors: [SettingDescriptor] {
        [
            SettingDescriptor(
                autoRoutePath, section: .home, group: SettingsText.keyed("settings.group.chiefSubagents", "Subagents"),
                title: SettingsText.keyed("settings.chief.autoRouteSubagents", "Route Subagents to the Best Agent"),
                help: SettingsText.keyed("settings.chief.autoRouteSubagents.help",
                                         "The Chief picks the agent each subagent runs on, such as Codex for long coding work and Claude for writing and UI, even when the Chief itself runs on another. Off, subagents run on the Chief's own agent."),
                kind: .toggle, default: .bool(false),
                keywords: ["chief", "subagent", "route", "routing", "harness", "codex", "claude", "agent", "auto"]
            ),
            SettingDescriptor(
                showWorkspacesPath, section: .home, group: SettingsText.keyed("settings.group.chiefSubagents", "Subagents"),
                title: SettingsText.keyed("settings.chief.subagentsShowWorkspaces", "Show Each Subagent in the Sidebar"),
                help: SettingsText.keyed("settings.chief.subagentsShowWorkspaces.help",
                                         "Each subagent the Chief starts gets its own workspace in the sidebar. Off, subagents run hidden and open from their links in the Chief's replies."),
                kind: .toggle, default: .bool(false),
                keywords: ["chief", "subagent", "workspace", "sidebar", "show", "hidden", "agent"]
            ),
            SettingDescriptor(
                closeFinishedPath, section: .home, group: SettingsText.keyed("settings.group.chiefSubagents", "Subagents"),
                title: SettingsText.keyed("settings.chief.subagentsCloseFinished", "Close Finished Subagent Workspaces"),
                help: SettingsText.keyed("settings.chief.subagentsCloseFinished.help",
                                         "When a subagent finishes, its workspace closes, so the sidebar keeps fewer workspaces. Off, a subagent's workspace stays until you close it."),
                kind: .toggle, default: .bool(false),
                keywords: ["chief", "subagent", "workspace", "sidebar", "close", "finished", "done", "auto", "agent"]
            ),
        ]
    }
}
