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
                    SettingChoice("auto", SettingsText.keyed("settings.choice.diffAutoLayout", "Auto")),
                    SettingChoice("split", SettingsText.keyed("settings.choice.diffSplit", "Side by Side")),
                    SettingChoice("unified", SettingsText.keyed("settings.choice.diffUnified", "Unified")),
                ]),
                default: .string("auto"), keywords: ["diff", "split", "unified", "side by side", "auto", "automatic"]
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
            // Settings only, no toolbar toggle: add/remove follow the theme unless a person opts out.
            SettingDescriptor(
                ["diff", "colors"], section: .appearance, group: group,
                title: SettingsText.keyed("settings.diff.colors", "Diff Colors"),
                kind: .choice([
                    SettingChoice("theme", SettingsText.keyed("settings.choice.diffColorsTheme", "Theme")),
                    SettingChoice("muted", SettingsText.keyed("settings.choice.diffColorsMuted", "Muted")),
                    SettingChoice("standard", SettingsText.keyed("settings.choice.standard", "Standard")),
                ]),
                default: .string("theme"), keywords: ["diff", "color", "green", "red", "added", "removed"]
            ),
            toggle("wordWrap", SettingsText.keyed("settings.diff.wordWrap", "Wrap Lines"), false, ["wrap", "lines"]),
            // On by default (Leo, 2026-10-20: the diff viewer shows word-level changes, as a code review does).
            toggle("wordDiffs", SettingsText.keyed("settings.diff.wordDiffs", "Highlight Word Changes"), true, ["word", "inline"]),
            toggle("lineNumbers", SettingsText.keyed("settings.diff.lineNumbers", "Line Numbers"), true, ["line numbers", "gutter"]),
            toggle("showBackgrounds", SettingsText.keyed("settings.diff.showBackgrounds", "Change Backgrounds"), true, ["background", "color"]),
            toggle("expandUnchanged", SettingsText.keyed("settings.diff.expandUnchanged", "Expand Unchanged Lines"), false,
                   ["unchanged", "context", "expand"]),
            // Off by default: the familiar order is the order the diff arrived in, and a reorder
            // nobody can turn off has no business being the default. The toolbar's toggle writes
            // this row, so turning it on now lasts past the tab (webviews/src/viewer-prefs.ts).
            toggle("groupByKind", SettingsText.keyed("settings.diff.groupByKind", "Group Files by Kind"), false,
                   ["group", "kind", "tests", "generated", "order", "sort"]),
            // Off by default: the diff shows every change, as git does. On, the diff leaves out white
            // space changes (`git diff --ignore-all-space`), for the git sources only; the "..." menu's
            // Hide white space writes this row.
            toggle("hideWhitespace", SettingsText.keyed("settings.diff.hideWhitespace", "Hide White Space"), false,
                   ["whitespace", "white space", "spaces", "indentation", "ignore"]),
            // On by default: the floating Stage All / Revert All bar at the diff's end. Off hides it;
            // each hunk's and file's own Stage and Revert stay.
            toggle("showBulkActions", SettingsText.keyed("settings.diff.showBulkActions", "Stage All and Revert All Bar"), true,
                   ["stage", "revert", "all", "floating", "bar", "bulk", "actions"]),
        ]
    }
}
