/// What a setting holds and how the Settings window edits it.
public nonisolated enum SettingKind: Sendable, Hashable {
    /// One of fixed values (a pop-up or segmented control).
    case choice([SettingChoice])
    /// A fixed value or a number (`browser.hibernation`: "off", "moderate",
    /// "aggressive" or minutes).
    case choiceOrNumber([SettingChoice], SettingNumber)
    case toggle
    case number(SettingNumber)
    /// `#RRGGBB` or `#RRGGBBAA`; absent means the theme's color.
    case color
    /// A sound: "default", "none" or a name in /System/Library/Sounds.
    case sound
    /// A web address, or empty for none.
    case url
    /// A list of host names.
    case hostList
    /// A list of folder paths, each absolute or `~/...` (`picker.pinned`).
    case folderList
    /// `{"start": "HH:MM", "end": "HH:MM"}`; absent means off.
    case timeRange
    /// A Ghostty theme: one theme name or `light:A,dark:B` (`AppThemeSetting`).
    case theme
    /// A font family name (`TerminalFontSetting`).
    case fontFamily
    /// A list of numbers, each in the range (`layout.columnWidthPresets`: strip width fractions).
    case numberList(SettingNumber)
    /// An object whose values are all strings (`sidebar.workspaceIcons`: workspace title to glyph).
    case stringMap
}
