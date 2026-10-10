import CmuxNextDesign

/// The agent pane composer's own keys in cmux.json (the pane reads the same names,
/// webviews/src/agent-session/acpmux/composerSettings.ts):
///
/// ```jsonc
/// "agentPane": { "showContextUsage": true, "composer": { "design": "today" } }
/// ```
///
/// `showContextUsage`: the context usage ring beside the model. The ring's right-click hides it,
/// the composer footer's right-click shows it again. A bad value is the default plus a diagnostic.
/// `design`: the base layout choice for the DEV/NIGHTLY composer preview. Release and RC hosts
/// resolve it to `today`; unknown values are ignored with a diagnostic.
public nonisolated struct AgentPaneComposerSetting: Sendable, Hashable {
    public static let showContextUsagePath = ["agentPane", "showContextUsage"]
    public static let designPath = ["agentPane", "composer", "design"]

    public var showContextUsage = true
    public var design = "today"

    public init() {}

    public static let fallback = AgentPaneComposerSetting()

    /// The page's value (the `composer` host event): `{showContextUsage, design}`.
    public var pageValue: JSONValue {
        ["showContextUsage": .bool(showContextUsage), "design": .string(design)]
    }

    /// Resolves the preview for the app channel before it is delivered to any page.
    /// Release and RC always send today's composer, even when cmux.json contains a preview choice.
    public func resolved(previewsEnabled: Bool) -> Self {
        var result = self
        result.design = previewsEnabled ? (AgentPaneComposerDesign.tunable.override?.rawValue ?? design) : "today"
        return result
    }

    /// Checked against its schema row, so the parser and the Settings window agree.
    static func parse(_ root: JSONValue, diagnostics: inout [SettingsDiagnostic]) -> AgentPaneComposerSetting {
        var setting = fallback
        for descriptor in AgentPaneComposerSettingsSchema.descriptors {
            guard let value = root.value(at: descriptor.path) else { continue }
            guard descriptor.accepts(value) else {
                diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: descriptor.id, message: OmnibarSettingsSchema.expectation(descriptor)))
                continue
            }
            if descriptor.path == showContextUsagePath, let flag = value.boolValue { setting.showContextUsage = flag }
            if descriptor.path == designPath, let design = value.stringValue { setting.design = design }
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
                AgentPaneComposerSetting.designPath, section: .general, group: group,
                title: SettingsText.keyed("settings.agentPane.composer.design", "Composer Design"),
                help: SettingsText.keyed("settings.agentPane.composer.design.help", "DEV/NIGHTLY preview layout for the agent composer."),
                kind: .choice(AgentPaneComposerDesign.allCases.map { SettingChoice($0.rawValue, $0.title) }),
                default: .string(AgentPaneComposerSetting.fallback.design),
                keywords: ["composer", "design", "layout", "preview", "DEV", "NIGHTLY"]
            ).hiddenFromSettingsPage("DEV/NIGHTLY preview; hidden in release settings"),
        ]
    }

    /// Looks only: agents may change it.
    static var agentSettableKeys: Set<String> { Set(descriptors.map(\.id)) }
}
