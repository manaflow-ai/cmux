import Foundation

/// Text of the shortcut recorder (table ShortcutRecorder), shared by the
/// palette's Cmd-K editor and the Settings window's Keyboard section.
public nonisolated enum ShortcutRecorderStrings {
    public static var editShortcut: String { text("palette.shortcut.edit", "Edit Keyboard Shortcut…") }
    public static var recorderTitle: String { text("palette.shortcut.title", "Edit Shortcut") }
    public static var recorderPrompt: String { text("palette.shortcut.prompt", "Press the new shortcut.") }
    public static var noShortcut: String { text("palette.shortcut.none", "No shortcut") }
    static var shortcutNeedsModifier: String { text("palette.shortcut.needsModifier", "A shortcut needs ⌘ or ⌃.") }
    static func shortcutReservedByMacOS(_ chord: String, _ feature: String) -> String {
        format("palette.shortcut.reservedByMacOS", "macOS uses %1$@ for %2$@. Choose another shortcut.", chord, feature)
    }
    static func shortcutOwnedBySystemAction(_ chord: String, _ action: String) -> String {
        format("palette.shortcut.systemAction", "%1$@ is %2$@, which always runs. Choose another shortcut.", chord, action)
    }
    static func shortcutInNumberedFamily(_ chord: String, _ action: String) -> String {
        format("palette.shortcut.numberedFamily", "%1$@ is part of %2$@. Choose another shortcut.", chord, action)
    }
    static func shortcutFamilyInConfig(_ id: String) -> String {
        format("palette.shortcut.familyInConfig", "Numbered shortcuts are edited in cmux-next.json (shortcuts.bindings.%@).", id)
    }
    static func shortcutUsedBy(_ chord: String, _ actions: String) -> String {
        format("palette.shortcut.usedBy", "%1$@ is used by %2$@.", chord, actions)
    }
    static var shortcutCanKeepBoth: String { text("palette.shortcut.canKeepBoth", "They run in different places, so both can keep it.") }
    static func shortcutTakesChromeChord(_ chord: String) -> String {
        format("palette.shortcut.takesChromeChord", "In a web page, cmux takes %@ from the page.", chord)
    }
    static func shortcutLeavesChromeChord(_ chord: String) -> String {
        format("palette.shortcut.leavesChromeChord", "In a web page, the page keeps %@; this action runs only elsewhere.", chord)
    }
    static func shortcutBeatsGhostty(_ keybind: String) -> String {
        format("palette.shortcut.beatsGhostty", "In a terminal, cmux runs before your Ghostty keybind (%@).", keybind)
    }
    static func shortcutSaved(_ chord: String) -> String { format("palette.shortcut.saved", "Shortcut saved: %@", chord) }
    static func shortcutSavedReplacing(_ chord: String, _ actions: String) -> String {
        format("palette.shortcut.savedReplacing", "Shortcut saved: %1$@ (removed from %2$@)", chord, actions)
    }
    static func shortcutUnchanged(_ chord: String) -> String { format("palette.shortcut.unchanged", "Shortcut unchanged: %@", chord) }
    static var shortcutRemoved: String { text("palette.shortcut.removed", "Shortcut removed") }
    static var defaultRestored: String { text("palette.shortcut.defaultRestored", "Default shortcut restored") }
    public static var optionSave: String { text("palette.shortcut.option.save", "Save") }
    public static var optionReplace: String { text("palette.shortcut.option.replace", "Replace") }
    public static var optionKeepBoth: String { text("palette.shortcut.option.keepBoth", "Keep Both") }
    public static var optionCancel: String { text("palette.shortcut.option.cancel", "Cancel") }
    public static var optionRemove: String { text("palette.shortcut.option.remove", "Remove Shortcut") }
    public static var optionRestoreDefault: String { text("palette.shortcut.option.restoreDefault", "Restore Default") }

    /// The button title for `option`.
    public static func title(_ option: ShortcutRecorderOption) -> String {
        switch option {
        case .save: optionSave
        case .replace: optionReplace
        case .keepBoth: optionKeepBoth
        case .cancel: optionCancel
        case .remove: optionRemove
        case .restoreDefault: optionRestoreDefault
        }
    }

    private static func text(_ key: StaticString, _ value: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: value, table: "ShortcutRecorder", bundle: .module)
    }

    private static func format(_ key: StaticString, _ value: String.LocalizationValue, _ args: any CVarArg...) -> String {
        String(format: text(key, value), locale: Locale.current, arguments: args)
    }
}
