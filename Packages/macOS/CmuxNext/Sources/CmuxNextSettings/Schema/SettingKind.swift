/// What a setting holds and how the Settings window edits it.
public nonisolated enum SettingKind: Sendable, Hashable {
    /// One of fixed values (a pop-up or segmented control).
    case choice([SettingChoice])
    /// A fixed value or a number (`browser.hibernation`: "off", "moderate",
    /// "aggressive" or minutes).
    case choiceOrNumber([SettingChoice], SettingNumber)
    /// A fixed value or an object whose only member `urlKey` is an http(s)
    /// origin (`home.server`: "hosted" or `{"selfHosted": "http://mini.tail1234.ts.net:7320"}`).
    case choiceOrURL([SettingChoice], urlKey: String)
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
    /// Free text, empty for none (`files.textEditor`: an app name, bundle ID or app path).
    case text
    /// A list of numbers, each in the range (`layout.columnWidthPresets`: strip width fractions).
    case numberList(SettingNumber)
    /// An object whose values are all strings (`sidebar.workspaceIcons`: workspace title to glyph).
    case stringMap
    /// An object of ``NotificationSoundRule``s by id or name (`notifications.sounds.workspaces`).
    case soundRules
    /// A list of non-empty strings (`notifications.mutedWorkspaces`: workspace ids).
    case stringList
    /// Choice values in an order the user picks; values left out follow in
    /// the default order (`sidebar.workspaceRow.secondLineOrder`). Exported
    /// as a `string_list` with `choices`, so older readers see a string list.
    case orderedChoices([SettingChoice])
    /// Any subset of the choices, kept in the choices' order; the page shows
    /// a switch per choice (`browser.toolbarButtons`). Exported as a
    /// `string_list` with `choices` and `ordered: false`.
    case choiceSet([SettingChoice])
}
