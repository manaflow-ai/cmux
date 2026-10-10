import CmuxNextDesign

nonisolated enum AgentPaneZoomSettingsSchema {
    static var descriptors: [SettingDescriptor] {
        [SettingDescriptor(
            AgentPaneZoomSetting.configPath, section: .general,
            group: SettingsText.keyed("settings.group.agentChat", "Agent Chat"),
            title: SettingsText.keyed("settings.agentPane.zoom", "Agent Chat Zoom"),
            help: SettingsText.keyed("settings.agentPane.zoom.help", "The display size for agent chat. Cmd-0 resets it."),
            kind: .number(SettingNumber(AgentPaneZoomSetting.range, step: AgentPaneZoomSetting.step,
                                        unit: .fraction, placeholder: AgentPaneZoomSetting.fallback)),
            default: .number(AgentPaneZoomSetting.fallback),
            keywords: ["agent", "chat", "zoom", "display", "size"]
        )]
    }
}
