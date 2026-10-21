/// Terminal output on disk and scrollback memory. The daemon (cmux-tui) reads these keys from
/// the settings export; the app only shows and validates them.
nonisolated enum TerminalOutputSetting {
    /// `terminal.persistence.mode`: what each terminal keeps on disk (`memory`, `snapshot`, `full`).
    /// `terminal.persistence` is not a leaf: its limits live beside the mode.
    static let modePath = ["terminal", "persistence", "mode"]
    static let modeDefault = "snapshot"
    /// Disk limits in bytes. Absent: the mode's own limit (the daemon decides it).
    static let maxBytesPerTerminalPath = ["terminal", "persistence", "maxBytesPerTerminal"]
    static let maxTotalBytesPath = ["terminal", "persistence", "maxTotalBytes"]
    static let diskBytesRange: ClosedRange<Double> = 1_048_576...107_374_182_400
    /// RAM for scrollback across all terminals, in bytes.
    static let maxTotalMemoryBytesPath = ["terminal", "scrollback", "maxTotalMemoryBytes"]
    static let maxTotalMemoryBytesDefault: Double = 268_435_456
    static let memoryBytesRange: ClosedRange<Double> = 16_777_216...68_719_476_736
    /// Byte fields step by 1 MiB; there is no byte unit, so they are plain counts.
    static let byteStep: Double = 1_048_576
}

/// One group of `SettingsSchema` rows (its own type: the schema type's line budget is per type).
nonisolated enum TerminalOutputSettingsSchema {
    static var descriptors: [SettingDescriptor] {
        let group = SettingsText.keyed("settings.group.terminalOutput", "Output and Scrollback")
        let modeDefault = SettingsText.keyed("settings.default.persistenceMode", "Mode Default")
        return [
            SettingDescriptor(
                TerminalOutputSetting.modePath, section: .terminal, group: group,
                title: SettingsText.keyed("settings.terminal.persistence.mode", "Terminal Output on Disk"),
                help: SettingsText.keyed("settings.terminal.persistence.mode.help",
                                         "Memory Only: nothing is written to disk. A restart of the Mac loses terminal output; a restart of cmux reconnects to the running terminals. Snapshot: each terminal saves one compressed screen and its recent lines, only when they changed (at most every 30 seconds, and at quit). Full Scrollback: each terminal saves all of its output, compressed, every few seconds, and older output loads again when you scroll up."),
                summary: SettingsText.keyed("settings.terminal.persistence.mode.summary", "What terminal output cmux keeps on disk"),
                kind: .choice([
                    SettingChoice("memory", SettingsText.keyed("settings.terminal.persistence.mode.memory", "Memory Only")),
                    SettingChoice("snapshot", SettingsText.keyed("settings.terminal.persistence.mode.snapshot", "Snapshot")),
                    SettingChoice("full", SettingsText.keyed("settings.terminal.persistence.mode.full", "Full Scrollback")),
                ]),
                default: .string(TerminalOutputSetting.modeDefault),
                keywords: ["persistence", "scrollback", "restore", "disk", "save", "output", "history", "privacy", "reboot"]
            ),
            SettingDescriptor(
                TerminalOutputSetting.maxBytesPerTerminalPath, section: .terminal, group: group,
                title: SettingsText.keyed("settings.terminal.persistence.maxBytesPerTerminal", "Disk Limit per Terminal (Bytes)"),
                help: SettingsText.keyed("settings.terminal.persistence.maxBytesPerTerminal.help",
                                         "The most saved output one terminal keeps on disk, in bytes, from 1 MiB to 100 GiB. Empty uses the mode's limit: 100 MB in Full Scrollback; Snapshot has its own small limit. The oldest saved output goes first."),
                kind: .number(SettingNumber(TerminalOutputSetting.diskBytesRange, step: TerminalOutputSetting.byteStep, unit: .count,
                                            placeholder: 104_857_600)),
                default: nil, defaultLabel: modeDefault,
                keywords: ["persistence", "scrollback", "disk", "limit", "size", "bytes", "storage"]
            ),
            SettingDescriptor(
                TerminalOutputSetting.maxTotalBytesPath, section: .terminal, group: group,
                title: SettingsText.keyed("settings.terminal.persistence.maxTotalBytes", "Disk Limit for All Terminals (Bytes)"),
                help: SettingsText.keyed("settings.terminal.persistence.maxTotalBytes.help",
                                         "The most saved output all terminals keep on disk together, in bytes, from 1 MiB to 100 GiB. Empty uses the mode's limit: 50 MB in Snapshot, 2 GB in Full Scrollback. The oldest saved output goes first."),
                kind: .number(SettingNumber(TerminalOutputSetting.diskBytesRange, step: TerminalOutputSetting.byteStep, unit: .count,
                                            placeholder: 2_147_483_648)),
                default: nil, defaultLabel: modeDefault,
                keywords: ["persistence", "scrollback", "disk", "limit", "size", "bytes", "storage", "total"]
            ),
            SettingDescriptor(
                TerminalOutputSetting.maxTotalMemoryBytesPath, section: .terminal, group: group,
                title: SettingsText.keyed("settings.terminal.scrollback.maxTotalMemoryBytes", "Scrollback Memory for All Terminals (Bytes)"),
                help: SettingsText.keyed("settings.terminal.scrollback.maxTotalMemoryBytes.help",
                                         "The most memory all terminals use together for scrollback, in bytes, from 16 MiB. The default is 256 MiB. The limit for one terminal is Ghostty's scrollback-limit. When the total is over this limit, idle and background terminals give back scrollback first."),
                kind: .number(SettingNumber(TerminalOutputSetting.memoryBytesRange, step: TerminalOutputSetting.byteStep, unit: .count)),
                default: .number(TerminalOutputSetting.maxTotalMemoryBytesDefault),
                keywords: ["scrollback", "memory", "ram", "limit", "bytes", "scrollback-limit", "ghostty", "total"]
            ),
        ]
    }
}
