import CmuxNextDesign

/// The defaults a new agent chat starts with (Agents > Agent Chat). acpmux
/// reads `agents.defaultPermissionMode` at each new chat
/// (`cmux-tui/crates/acpmux/src/hub/start_mode.rs`): a mode picked in a chat
/// applies to that chat only (Leo 2026-10-21). A value MDM or the team
/// policy forces reaches acpmux through the app's settings push
/// (`ChatSettings`) and wins over the settings file.
///
/// `agents.modelRouter.model`: the model the cmux model router profile (`cmux`) starts new chats
/// on. acpmux reads it when it builds that profile (`cmux-tui/crates/acpmux/src/config/discover.rs`
/// `add_cmux_router`) and reloads the profile when the setting changes. The choices are the router's
/// DeepSeek models (user 2026-10-28: DeepSeek only, the 10/17 build with images by default); the
/// backend allowlist (`INFERENCE_MODEL_ALLOWLIST`) holds the same list.
nonisolated enum AgentDefaultsSettingsSchema {
    static let permissionModePath = ["agents", "defaultPermissionMode"]
    static let modelRouterModelPath = ["agents", "modelRouter", "model"]
    /// The router's DeepSeek models, default first (`CMUX_ROUTER_MODELS` in acpmux lists the same ids).
    static var modelRouterChoices: [SettingChoice] {
        [
            SettingChoice("deepseek/deepseek-v4.1-flash-1017",
                          SettingsText.keyed("settings.choice.modelRouterDeepSeekV41Flash1017", "DeepSeek V4.1 Flash 1017 (Images)")),
            SettingChoice("deepseek/deepseek-v4.1-flash",
                          SettingsText.keyed("settings.choice.modelRouterDeepSeekV41Flash", "DeepSeek V4.1 Flash")),
            SettingChoice("deepseek/deepseek-v4-flash",
                          SettingsText.keyed("settings.choice.modelRouterDeepSeekV4Flash", "DeepSeek V4 Flash")),
            SettingChoice("deepseek/deepseek-v4-pro",
                          SettingsText.keyed("settings.choice.modelRouterDeepSeekV4Pro", "DeepSeek V4 Pro")),
        ]
    }

    static var descriptors: [SettingDescriptor] {
        [SettingDescriptor(
            permissionModePath, section: .general,
            group: SettingsText.keyed("settings.group.agentChat", "Agent Chat"),
            title: SettingsText.keyed("settings.agents.defaultPermissionMode", "Permission Mode for New Chats"),
            help: SettingsText.keyed("settings.agents.defaultPermissionMode.help",
                                     "What a new chat may do without asking. A mode you pick in a chat applies to that chat only."),
            kind: .choice([
                SettingChoice("fullAccess", SettingsText.keyed("settings.choice.permissionFullAccess", "Full Access")),
                SettingChoice("standard", SettingsText.keyed("settings.choice.permissionStandard", "Harness Default")),
                SettingChoice("ask", SettingsText.keyed("settings.choice.permissionAsk", "Ask Before Changes")),
            ]),
            default: .string("fullAccess"),
            keywords: ["permission", "mode", "full access", "ask", "approval", "yolo", "bypass", "agent", "new chat"]
        ), SettingDescriptor(
            modelRouterModelPath, section: .general,
            group: SettingsText.keyed("settings.group.agentChat", "Agent Chat"),
            title: SettingsText.keyed("settings.agents.modelRouter.model", "cmux Model Router Model"),
            help: SettingsText.keyed("settings.agents.modelRouter.model.help",
                                     "The model a new chat on the cmux model router starts on. A model you pick in a chat applies to that chat only."),
            kind: .choice(modelRouterChoices),
            default: .string("deepseek/deepseek-v4.1-flash-1017"),
            keywords: ["model", "router", "cmux router", "deepseek", "vision", "images", "inference", "default model", "new chat"]
        )]
    }
}
