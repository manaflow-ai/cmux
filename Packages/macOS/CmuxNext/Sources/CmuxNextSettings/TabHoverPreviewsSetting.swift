public import CmuxNextDesign

/// `tabs.hoverPreviews` in cmux.json (`TabHoverPreviews`): "full" (the
/// default) shows a tab's card with its thumbnail, "compact" the card without
/// it. Turning cards off is `sidebar.hoverCards.enabled`. A missing key is the
/// default; a bad value is the default plus a diagnostic.
public nonisolated struct TabHoverPreviewsSetting: Sendable {
    public static let configPath = ["tabs", "hoverPreviews"]
    public static let fallback: TabHoverPreviews = .full

    public init() {}

    static func parse(_ root: JSONValue, diagnostics: inout [SettingsDiagnostic]) -> TabHoverPreviews {
        guard let value = root.value(at: configPath) else { return fallback }
        guard let text = value.stringValue, let previews = TabHoverPreviews(rawValue: text) else {
            let choices = TabHoverPreviews.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: ", ")
            diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: configPath.joined(separator: "."),
                                                  message: "expected one of \(choices)"))
            return fallback
        }
        return previews
    }

    static func descriptor(group: SettingText) -> SettingDescriptor {
        SettingDescriptor(
            configPath, section: .general, group: group,
            title: SettingsText.keyed("settings.tabs.hoverPreviews", "Hover Previews"),
            help: SettingsText.keyed("settings.tabs.hoverPreviews.help",
                                     "What resting the pointer on a tab shows: its title, memory and what it is doing, with a thumbnail in Full."),
            kind: .choice([
                SettingChoice(TabHoverPreviews.compact.rawValue, SettingsText.keyed("settings.choice.compact", "Compact")),
                SettingChoice(TabHoverPreviews.full.rawValue, SettingsText.keyed("settings.choice.hoverPreviews.full", "Full")),
            ]),
            default: .string(fallback.rawValue),
            keywords: ["tabs", "hover", "preview", "card", "tooltip", "thumbnail", "memory", "compact"]
        )
    }
}

extension SettingsApplier {
    /// Copies `tabs.hoverPreviews` into `design`, writing only a change.
    static func applyTabHoverPreviews(_ snapshot: CmuxConfigSnapshot, to design: DesignSettings) {
        var ignored: [SettingsDiagnostic] = [] // the parse reported them (`ChromePlacementSetting.parse`)
        let previews = TabHoverPreviewsSetting.parse(snapshot.root, diagnostics: &ignored)
        if design.tabHoverPreviews != previews { design.tabHoverPreviews = previews }
    }
}
