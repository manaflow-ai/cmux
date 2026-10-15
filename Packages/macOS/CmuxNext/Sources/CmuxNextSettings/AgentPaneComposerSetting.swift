import CmuxNextDesign

/// The agent pane composer's own keys in cmux.json (the pane reads the same names,
/// webviews/src/agent-session/acpmux/composerSettings.ts):
///
/// ```jsonc
/// "agentPane": { "showContextUsage": true, "showDictation": true, "reasoningSlider": false }
/// ```
///
/// `showContextUsage`: the context usage ring beside the model. The ring's right-click hides it,
/// the composer footer's right-click shows it again. `showDictation`: the dictation mic beside Send
/// in every composer (a chat's and the New Tab page's); its right-click hides it, Settings shows it
/// again. `reasoningSlider`: the composer's reasoning menu shows the stepped slider instead of its
/// list of levels (opt-in, off by default; Settings changes it). A bad value is the default plus a
/// diagnostic.
public nonisolated struct AgentPaneComposerSetting: Sendable, Hashable {
    public static let showContextUsagePath = ["agentPane", "showContextUsage"]
    public static let showDictationPath = ["agentPane", "showDictation"]
    public static let reasoningSliderPath = ["agentPane", "reasoningSlider"]

    public var showContextUsage = true
    public var showDictation = true
    public var reasoningSlider = false

    public init() {}

    public static let fallback = AgentPaneComposerSetting()

    /// The page's value (the `composer` host event): `{showContextUsage, showDictation, reasoningSlider}`.
    public var pageValue: JSONValue {
        [
            "showContextUsage": .bool(showContextUsage),
            "showDictation": .bool(showDictation),
            "reasoningSlider": .bool(reasoningSlider)
        ]
    }

    /// Checked against its schema row, so the parser and the Settings window agree.
    static func parse(_ root: JSONValue, diagnostics: inout [SettingsDiagnostic]) -> AgentPaneComposerSetting {
        var setting = fallback
        for descriptor in AgentPaneComposerSettingsSchema.descriptors {
            guard let value = root.value(at: descriptor.path) else { continue }
            guard descriptor.accepts(value), let flag = value.boolValue else {
                diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: descriptor.id, message: OmnibarSettingsSchema.expectation(descriptor)))
                continue
            }
            if descriptor.path == showContextUsagePath { setting.showContextUsage = flag }
            if descriptor.path == showDictationPath { setting.showDictation = flag }
            if descriptor.path == reasoningSliderPath { setting.reasoningSlider = flag }
        }
        return setting
    }
}

/// The composer's rows (General > Agent Chat, next to the edited-files card's).
nonisolated enum AgentPaneComposerSettingsSchema {
    static var descriptors: [SettingDescriptor] {
        let group = SettingsText.keyed("settings.group.agentChat", "Agent Chat")
        return [
            SettingDescriptor(
                AgentPaneComposerSetting.showContextUsagePath, section: .general, group: group,
                title: SettingsText.keyed("settings.agentPane.showContextUsage", "Show Context Usage"),
                help: SettingsText.keyed("settings.agentPane.showContextUsage.help",
                                         "The ring beside the model that fills as the chat uses its context window."),
                kind: .toggle, default: .bool(AgentPaneComposerSetting.fallback.showContextUsage),
                keywords: ["context", "usage", "tokens", "window", "ring", "composer", "agent"]
            ),
            SettingDescriptor(
                AgentPaneComposerSetting.showDictationPath, section: .general, group: group,
                title: SettingsText.keyed("settings.agentPane.showDictation", "Show Dictation Button"),
                help: SettingsText.keyed("settings.agentPane.showDictation.help",
                                         "The microphone beside Send in every composer, including the New Tab page."),
                kind: .toggle, default: .bool(AgentPaneComposerSetting.fallback.showDictation),
                keywords: ["dictation", "microphone", "mic", "voice", "speech", "composer", "agent", "new tab"]
            ),
            SettingDescriptor(
                AgentPaneComposerSetting.reasoningSliderPath, section: .general, group: group,
                title: SettingsText.keyed("settings.agentPane.reasoningSlider", "Use Reasoning Slider"),
                help: SettingsText.keyed("settings.agentPane.reasoningSlider.help",
                                         "The composer's reasoning menu shows a slider from Faster to Smarter instead of a list of levels."),
                kind: .toggle, default: .bool(AgentPaneComposerSetting.fallback.reasoningSlider),
                keywords: ["reasoning", "effort", "thinking", "slider", "level", "composer", "agent"]
            ),
        ]
    }

    /// Looks only: agents may change it.
    static var agentSettableKeys: Set<String> { Set(descriptors.map(\.id)) }
}
