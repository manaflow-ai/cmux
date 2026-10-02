import Foundation

extension Array where Element == CuratedSettingEntry {
    /// Search entries for the native Ghostty option rows in Settings > Terminal
    /// (`TerminalGhosttyOptionsCard`). Each row anchors itself with the matching
    /// `setting:terminal:<id>` id, and the synonyms carry its Ghostty key.
    static var terminalGhosttyOptionEntries: [CuratedSettingEntry] {
        [
            .init(
                section: .terminal,
                id: "font-family",
                title: String(localized: "settings.terminal.ghostty.fontFamily", defaultValue: "Font"),
                synonyms: "font-family font family typeface monospaced monospace terminal font ghostty nerd font"
            ),
            .init(
                section: .terminal,
                id: "font-size",
                title: String(localized: "settings.terminal.ghostty.fontSize", defaultValue: "Font Size"),
                synonyms: "font-size terminal font size text size points pt bigger smaller zoom ghostty"
            ),
            .init(
                section: .terminal,
                id: "cursor-style",
                title: String(localized: "settings.terminal.ghostty.cursorStyle", defaultValue: "Cursor Style"),
                synonyms: "cursor-style cursor shape block bar beam underline hollow caret ghostty"
            ),
            .init(
                section: .terminal,
                id: "cursor-blink",
                title: String(localized: "settings.terminal.ghostty.cursorBlink", defaultValue: "Blinking Cursor"),
                synonyms: "cursor-style-blink cursor blink blinking flash caret ghostty"
            ),
            .init(
                section: .terminal,
                id: "window-padding-x",
                title: String(localized: "settings.terminal.ghostty.windowPaddingX", defaultValue: "Horizontal Padding"),
                synonyms: "window-padding-x window padding horizontal left right margin inset spacing ghostty"
            ),
            .init(
                section: .terminal,
                id: "window-padding-y",
                title: String(localized: "settings.terminal.ghostty.windowPaddingY", defaultValue: "Vertical Padding"),
                synonyms: "window-padding-y window padding vertical top bottom margin inset spacing ghostty"
            ),
            .init(
                section: .terminal,
                id: "background-opacity",
                title: String(localized: "settings.terminal.ghostty.backgroundOpacity", defaultValue: "Background Opacity"),
                synonyms: "background-opacity background opacity transparency transparent translucent see through alpha ghostty"
            ),
            .init(
                section: .terminal,
                id: "background-blur",
                title: String(localized: "settings.terminal.ghostty.backgroundBlur", defaultValue: "Background Blur"),
                synonyms: "background-blur background blur frosted glass vibrancy transparent translucent ghostty"
            ),
            .init(
                section: .terminal,
                id: "option-as-alt",
                title: String(localized: "settings.terminal.ghostty.optionAsAlt", defaultValue: "Option as Alt"),
                synonyms: "macos-option-as-alt option as alt meta key left option right option alt key keyboard ghostty"
            ),
            .init(
                section: .terminal,
                id: "scrollback-limit",
                title: String(localized: "settings.terminal.ghostty.scrollbackLimit", defaultValue: "Scrollback Limit"),
                synonyms: "scrollback-limit scrollback history buffer lines memory megabytes mb ghostty"
            ),
        ]
    }
}
