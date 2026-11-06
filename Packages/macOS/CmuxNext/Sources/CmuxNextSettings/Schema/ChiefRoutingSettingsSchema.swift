/// Settings > Chief > Subagents: whether the Chief may route each subagent to the harness best at its task
/// (`spawn(harness)`: Codex for long coding, Claude for writing and UI), whatever harness the Chief itself
/// runs on (Leo 2026-11-01: "maybe toggle off-able but if you look into grokbot they auto route stuff all the
/// time"). Off by default (Leo 2026-11-01: "optional ofc we don't wanna change defaults or whatnot yet"); a Chief's
/// own `chief engine set --subagent-routing auto|off` wins over it. The Chief host reads the key at each spawn,
/// so a change applies at once.
nonisolated enum ChiefRoutingSettingsSchema {
    static let autoRoutePath = ["chief", "autoRouteSubagents"]
    static let keys: Set<String> = [autoRoutePath.joined(separator: ".")]

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
        ]
    }
}
