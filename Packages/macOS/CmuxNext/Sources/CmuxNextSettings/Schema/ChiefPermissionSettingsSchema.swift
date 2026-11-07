/// Settings > Chief > Engine: the permission mode the Chief's own Claude turns run in (cmux#37392: "there is no
/// way for me to switch this to dangerously-skip-permissions? ... it should be default on that right?"). Bypass
/// (Claude Code's `bypassPermissions`) by default: the Chief never asks (Lawrence 2026-10-20), and its subagents
/// and chats already run at the person's full-access start level. Auto lets Claude Code's safety classifier judge
/// each call; Manual (`default`) refuses each call Claude Code would ask about: its turn runs under acpmux's `ask`
/// policy, where nobody can answer a turn session's request. The Chief host reads the key at each turn start, so a change applies
/// from the next turn. A Chief's own `chief engine set --mode` picks within it: never wider than this setting.
nonisolated enum ChiefPermissionSettingsSchema {
    static let modePath = ["chief", "permissionMode"]
    static let keys: Set<String> = [modePath.joined(separator: ".")]

    static var descriptors: [SettingDescriptor] {
        [
            SettingDescriptor(
                modePath, section: .home, group: SettingsText.keyed("settings.group.chiefEngine", "Engine"),
                title: SettingsText.keyed("settings.chief.permissionMode", "Chief Permission Mode"),
                help: SettingsText.keyed("settings.chief.permissionMode.help",
                                         "How the Chief's own turns handle permissions. Bypass runs every command without asking. Auto lets a safety check decide each command. Manual refuses each change that would need approval. Applies from the next turn."),
                kind: .choice([
                    SettingChoice("bypassPermissions", SettingsText.keyed("settings.choice.chiefPermissionMode.bypass", "Bypass")),
                    SettingChoice("auto", SettingsText.keyed("settings.choice.chiefPermissionMode.auto", "Auto")),
                    SettingChoice("default", SettingsText.keyed("settings.choice.chiefPermissionMode.manual", "Manual")),
                ]),
                default: .string("bypassPermissions"),
                keywords: ["chief", "permission", "mode", "bypass", "dangerously", "skip", "yolo", "auto", "manual", "ask", "approval"]
            ),
        ]
    }
}
