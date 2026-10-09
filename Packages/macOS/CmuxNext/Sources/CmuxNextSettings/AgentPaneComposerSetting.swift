import CmuxNextDesign

/// The agent pane composer's own keys in cmux.json (the pane reads the same names,
/// webviews/src/agent-session/acpmux/composerSettings.ts):
///
/// ```jsonc
/// "agentPane": { "showContextUsage": true }
/// ```
///
/// `showContextUsage`: the context usage ring beside the model. The ring's right-click hides it,
/// the composer footer's right-click shows it again. A bad value is the default plus a diagnostic.
public nonisolated struct AgentPaneComposerSetting: Sendable, Hashable {
    public static let showContextUsagePath = ["agentPane", "showContextUsage"]

    public var showContextUsage = true

    public init() {}

    public static let fallback = AgentPaneComposerSetting()

    /// The page's value (the `composer` host event): `{showContextUsage}`.
    public var pageValue: JSONValue { ["showContextUsage": .bool(showContextUsage)] }

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
        ]
    }

    /// Looks only: agents may change it.
    static var agentSettableKeys: Set<String> { Set(descriptors.map(\.id)) }
}
