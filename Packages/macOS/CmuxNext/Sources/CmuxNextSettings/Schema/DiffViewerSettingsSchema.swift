/// The diff page's display keys (diff-host S4; React UIs lead review P2-3): `diff.<key>`, the
/// toolbar toggles the page keeps (webviews/src/viewer-prefs.ts `sanitizeViewerPrefs`), with the
/// page's own defaults. cmux-next reads them; an agent may set them (looks only). The files a
/// person collapsed are not a setting: the diff host keeps them next to its viewed marks.
nonisolated enum DiffViewerSettingsSchema {
    /// `diff.<key>` of every row (the agent-settable keys).
    static var keys: Set<String> { Set(descriptors.map(\.id)) }

    static var descriptors: [SettingDescriptor] {
        let group = SettingsText.keyed("settings.group.diffViewer", "Diff Viewer")
        func toggle(_ key: String, _ title: SettingText, _ value: Bool, _ keywords: [String]) -> SettingDescriptor {
            SettingDescriptor(["diff", key], section: .appearance, group: group, title: title, kind: .toggle,
                              default: .bool(value), keywords: ["diff"] + keywords)
        }
        return [
            SettingDescriptor(
                ["diff", "layout"], section: .appearance, group: group,
                title: SettingsText.keyed("settings.diff.layout", "Layout"),
                kind: .choice([
                    SettingChoice("split", SettingsText.keyed("settings.choice.diffSplit", "Side by Side")),
                    SettingChoice("unified", SettingsText.keyed("settings.choice.diffUnified", "Unified")),
                ]),
                default: .string("unified"), keywords: ["diff", "split", "unified", "side by side"]
            ),
            SettingDescriptor(
                ["diff", "diffIndicators"], section: .appearance, group: group,
                title: SettingsText.keyed("settings.diff.diffIndicators", "Change Markers"),
                kind: .choice([
                    SettingChoice("bars", SettingsText.keyed("settings.choice.diffBars", "Bars")),
                    SettingChoice("classic", SettingsText.keyed("settings.choice.diffClassic", "+ and −")),
                    SettingChoice("none", SettingsText.keyed("settings.choice.diffNone", "None")),
                ]),
                default: .string("bars"), keywords: ["diff", "indicators", "markers", "gutter"]
            ),
            toggle("wordWrap", SettingsText.keyed("settings.diff.wordWrap", "Wrap Lines"), false, ["wrap", "lines"]),
            toggle("wordDiffs", SettingsText.keyed("settings.diff.wordDiffs", "Highlight Word Changes"), false, ["word", "inline"]),
            toggle("lineNumbers", SettingsText.keyed("settings.diff.lineNumbers", "Line Numbers"), true, ["line numbers", "gutter"]),
            toggle("showBackgrounds", SettingsText.keyed("settings.diff.showBackgrounds", "Change Backgrounds"), true, ["background", "color"]),
            toggle("expandUnchanged", SettingsText.keyed("settings.diff.expandUnchanged", "Expand Unchanged Lines"), false,
                   ["unchanged", "context", "expand"]),
        ]
    }
}
