public import CmuxNextDesign

/// Layout choices for the real composer, exposed in DEV/NIGHTLY Debug Settings.
public nonisolated enum AgentPaneComposerDesign: String, Sendable, CaseIterable, TunableChoice {
    /// The shipped composer; also the default when the preview is off.
    case today
    /// Controls above a rounded writing capsule.
    case halo
    /// A writing area with a vertical control rail beside it.
    case rail
    /// An unboxed note with actions in its left margin.
    case notch

    /// The localized name shared by Settings and Debug Settings.
    public var title: SettingText {
        switch self {
        case .today: SettingsText.keyed("settings.choice.composerToday", "Today")
        case .halo: SettingsText.keyed("settings.choice.composerHalo", "Halo")
        case .rail: SettingsText.keyed("settings.choice.composerRail", "Rail")
        case .notch: SettingsText.keyed("settings.choice.composerNotch", "Notch")
        }
    }

    public var tunableTitle: String { title.text }

    /// The one preview switch; the app's inert tunable store hides it in Release and RC.
    public static let tunable = Tunable<AgentPaneComposerDesign>.choice(
        "agentPane.composer.design",
        TunableSection(id: "agentComposer", title: SettingsText.keyed("settings.group.agentChat", "Agent Chat").text,
                       symbol: "text.bubble", order: 47),
        SettingsText.keyed("settings.agentPane.composer.design", "Composer Design").text,
        help: SettingsText.keyed("settings.agentPane.composer.design.help", "DEV/NIGHTLY preview layout for the agent composer.").text,
        default: .today, code: "AgentPaneComposerDesign.tunable")
}
