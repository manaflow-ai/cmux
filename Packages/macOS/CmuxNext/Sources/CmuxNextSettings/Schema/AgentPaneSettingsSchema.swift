/// The agent chat's reply rows (decisions D4 and D5): what a path chip outside the session's
/// folders does, and when a web image in a reply loads. Both decide what leaves the project or
/// the machine, so an agent may not change them (``SettingsSchema/agentRefusedKeys``).
nonisolated enum AgentPaneSettingsSchema {
    static var descriptors: [SettingDescriptor] {
        let group = SettingsText.keyed("settings.group.agentChat", "Agent Chat")
        return [
            SettingDescriptor(
                AgentPaneReplySetting.outsideRootsPath, section: .general, group: group,
                title: SettingsText.keyed("settings.agentPane.outsideRoots", "Files Outside the Project"),
                help: SettingsText.keyed("settings.agentPane.outsideRoots.help",
                                         "What a file link in a reply does when the file is outside the chat's folders. Keys and .env files never open."),
                kind: .choice([
                    SettingChoice("confirm", SettingsText.keyed("settings.choice.agentPaneConfirm", "Ask First")),
                    SettingChoice("text", SettingsText.keyed("settings.choice.agentPaneText", "Show as Text")),
                    SettingChoice("open", SettingsText.keyed("settings.choice.agentPaneOpen", "Open")),
                ]),
                default: .string(AgentPaneReplySetting.fallback.outsideRoots.rawValue),
                keywords: ["agent", "chat", "link", "path", "file", "outside", "project"]
            ),
            SettingDescriptor(
                AgentPaneReplySetting.remoteImagesPath, section: .general, group: group,
                title: SettingsText.keyed("settings.agentPane.remoteImages", "Web Images in Replies"),
                help: SettingsText.keyed("settings.agentPane.remoteImages.help",
                                         "A web image loads from its site, which then sees that you read the reply."),
                kind: .choice([
                    SettingChoice("click", SettingsText.keyed("settings.choice.agentPaneClick", "Load on Click")),
                    SettingChoice("never", SettingsText.keyed("settings.choice.never", "Never")),
                    SettingChoice("always", SettingsText.keyed("settings.choice.always", "Always")),
                ]),
                default: .string(AgentPaneReplySetting.fallback.remoteImages.rawValue),
                keywords: ["agent", "chat", "image", "remote", "web", "privacy", "tracking"]
            ),
        ]
    }

    /// The rows' ids.
    static var keys: Set<String> { Set(descriptors.map(\.id)) }
}
