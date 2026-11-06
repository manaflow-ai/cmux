/// One group of `SettingsSchema` rows (its own type: the schema type's line budget is per type).
nonisolated enum TerminalSettingsSchema {
    /// `terminal.fontFamily` and `terminal.fontSize` (Ghostty overrides,
    /// `TerminalFontSetting`), `terminal.linkOpener.*` (`TerminalLinkOpener`), and
    /// `terminal.term` (`TerminalTermSetting`).
    static var descriptors: [SettingDescriptor] {
        let font = SettingsText.keyed("settings.group.terminalFont", "Font")
        let ghostty = SettingsText.keyed("settings.source.ghostty", "Ghostty")
        let links = SettingsText.keyed("settings.group.openingLinks", "Opening Links")
        let compatibility = SettingsText.keyed("settings.group.terminalCompatibility", "Compatibility")
        return [
            SettingDescriptor(
                TerminalFontSetting().familyPath, section: .terminal, group: font,
                title: SettingsText.keyed("settings.terminal.fontFamily", "Font Family"),
                help: SettingsText.keyed("settings.terminal.fontFamily.help", "A monospaced font installed on this Mac."),
                kind: .fontFamily, default: nil, defaultLabel: ghostty,
                keywords: ["font", "typeface", "monospace", "monospaced", "font-family", "ghostty"]
            ),
            SettingDescriptor(
                TerminalFontSetting().sizePath, section: .terminal, group: font,
                title: SettingsText.keyed("settings.terminal.fontSize", "Font Size"),
                kind: .number(SettingNumber(TerminalFontSetting().sizeRange, step: 1, unit: .points, placeholder: 13)),
                default: nil, defaultLabel: ghostty,
                keywords: ["font", "text", "size", "zoom", "font-size", "ghostty"]
            ),
            SettingDescriptor(
                TerminalLinkOpener.defaultPath, section: .terminal, group: links,
                title: SettingsText.keyed("settings.terminal.linkOpener.default", "Open Program Links In"),
                help: SettingsText.keyed("settings.terminal.linkOpener.default.help",
                                         "Where a URL goes when a program in a terminal opens a browser, such as aws login or gh auth login: cmux, system, chrome, safari, arc, firefox, edge, brave, app:<name>, a profile after @ (chrome@Profile 1), or command:<command> to let your script decide. A BROWSER you set yourself wins."),
                kind: .text, default: .string("cmux"),
                keywords: ["browser", "open", "url", "link", "BROWSER", "xdg-open", "login", "oauth", "default browser", "chrome", "safari", "profile"]
            ),
            SettingDescriptor(
                TerminalLinkOpener.rulesPath, section: .terminal, group: links,
                title: SettingsText.keyed("settings.terminal.linkOpener.rules", "Program Link Rules"),
                help: SettingsText.keyed("settings.terminal.linkOpener.rules.help",
                                         "Checked in order before the default; the first match wins. Write <match> -> <target>: caller:aws matches the program that opened the URL, and text, * wildcards or re: match the URL. Example: caller:gh github.com -> safari"),
                summary: SettingsText.keyed("settings.terminal.linkOpener.rules.summary", "Rules for program links"),
                kind: .stringList, default: .array([]),
                keywords: ["browser", "rules", "url", "link", "caller", "regex", "profile", "script"]
            ),
            SettingDescriptor(
                TerminalTermSetting.configPath, section: .terminal, group: compatibility,
                title: SettingsText.keyed("settings.terminal.term", "Terminal Type (TERM)"),
                help: SettingsText.keyed("settings.terminal.term.help",
                                         "The TERM new terminals start with. xterm-256color works on every host you ssh to. xterm-ghostty needs Ghostty's terminfo on each of those hosts, and applies only when it is installed on this Mac."),
                kind: .choice([
                    SettingChoice(TerminalTerm.xterm256color.rawValue, SettingsText.keyed("settings.choice.xterm256color", "xterm-256color (standard)")),
                    SettingChoice(TerminalTerm.xtermGhostty.rawValue, SettingsText.keyed("settings.choice.xtermGhostty", "xterm-ghostty")),
                ]),
                default: .string(TerminalTermSetting.fallback.rawValue),
                keywords: ["TERM", "terminfo", "xterm", "xterm-256color", "xterm-ghostty", "ssh", "htop", "ncurses", "terminal type", "compatibility"]
            ),
        ]
    }
}
