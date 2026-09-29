// Catalog rows for one inventory domain. Titles live in Localizable.xcstrings (en, ja).

extension ActionCatalog {
    static func settingsActions() -> [ActionDescriptor] {
        [
            ActionDescriptor(
                id: "reloadConfiguration",
                title: String(localized: "action.reloadConfiguration", defaultValue: "Reload Configuration", bundle: .module),
                keywords: ["config", "cmux.json", "ghostty"],
                defaultShortcut: Shortcut(",", modifiers: [.command, .shift]), category: .settings,
                symbol: "arrow.clockwise", surfaces: [.keyboard, .menu]
            ),
            ActionDescriptor(
                id: "palette.openCmuxSettingsFile",
                title: String(localized: "action.palette.openCmuxSettingsFile", defaultValue: "Open cmux.json", bundle: .module),
                keywords: ["config", "settings", "file"], category: .settings, symbol: "curlybraces",
                surfaces: [.palette, .menu]
            ),
            ActionDescriptor(
                id: "palette.openGhosttySettings",
                title: String(localized: "action.palette.openGhosttySettings", defaultValue: "Open Ghostty Config", bundle: .module),
                keywords: ["config", "settings", "file"], category: .settings, symbol: "doc.plaintext",
                surfaces: [.palette, .menu]
            ),
            ActionDescriptor(
                id: "palette.makeDefaultTerminal",
                title: String(localized: "action.palette.makeDefaultTerminal", defaultValue: "Make cmux the Default Terminal", bundle: .module),
                keywords: ["default", "handler"], category: .settings, symbol: "checkmark.seal",
                surfaces: [.palette, .menu]
            ),
            ActionDescriptor(
                id: "palette.toggleSetting",
                title: String(localized: "action.palette.toggleSetting", defaultValue: "Toggle Setting…", bundle: .module),
                keywords: ["preferences", "enable", "disable"], category: .settings, symbol: "switch.2",
                surfaces: [.palette], input: .list
            ),
            ActionDescriptor(
                id: "palette.shortcutKeymap",
                title: String(localized: "action.palette.shortcutKeymap", defaultValue: "Base Keymap…", bundle: .module),
                keywords: ["shortcuts", "preset", "vim"], category: .settings, symbol: "keyboard.badge.eye",
                surfaces: [.palette], input: .list
            ),
            ActionDescriptor(
                id: "palette.searchShortcuts",
                title: String(localized: "action.palette.searchShortcuts", defaultValue: "Search Keyboard Shortcuts…", bundle: .module),
                keywords: ["shortcuts", "keybindings", "hotkeys", "help"], category: .settings, symbol: "keyboard",
                surfaces: [.palette, .menu], input: .list
            ),
            ActionDescriptor(
                id: "palette.installCLI",
                title: String(localized: "action.palette.installCLI", defaultValue: "Install cmux CLI in PATH", bundle: .module),
                keywords: ["command line", "shell"], category: .settings, symbol: "terminal", surfaces: [.palette]
            ),
            ActionDescriptor(
                id: "palette.uninstallCLI",
                title: String(localized: "action.palette.uninstallCLI", defaultValue: "Uninstall cmux CLI from PATH", bundle: .module),
                keywords: ["command line", "shell"], category: .settings, symbol: "terminal.fill", surfaces: [.palette]
            ),
            ActionDescriptor(
                id: "palette.restartSocketListener",
                title: String(localized: "action.palette.restartSocketListener", defaultValue: "Restart CLI Listener", bundle: .module),
                keywords: ["socket", "cli"], category: .settings, symbol: "antenna.radiowaves.left.and.right",
                surfaces: [.palette]
            ),
            ActionDescriptor(
                id: "palette.checkForUpdates",
                title: String(localized: "action.palette.checkForUpdates", defaultValue: "Check for Updates…", bundle: .module),
                keywords: ["update", "version", "sparkle"], category: .settings, symbol: "arrow.down.circle",
                surfaces: [.palette, .menu]
            ),
            ActionDescriptor(
                id: "palette.applyUpdateIfAvailable",
                title: String(localized: "action.palette.applyUpdateIfAvailable", defaultValue: "Install Available Update", bundle: .module),
                keywords: ["update", "install"], category: .settings, symbol: "arrow.down.circle.fill",
                surfaces: [.palette, .menu]
            ),
            ActionDescriptor(
                id: "palette.attemptUpdate",
                title: String(localized: "action.palette.attemptUpdate", defaultValue: "Attempt Update", bundle: .module),
                keywords: ["update", "retry"], category: .settings, symbol: "arrow.triangle.2.circlepath",
                surfaces: [.palette]
            ),
            ActionDescriptor(
                id: "palette.switchAppChannel",
                title: String(localized: "action.palette.switchAppChannel", defaultValue: "Switch Update Channel…", bundle: .module),
                keywords: ["nightly", "beta", "stable", "channel"], category: .settings,
                symbol: "antenna.radiowaves.left.and.right.circle", surfaces: [.palette, .menu], input: .list
            ),
            ActionDescriptor(
                id: "palette.pro.upgrade",
                title: String(localized: "action.palette.pro.upgrade", defaultValue: "Upgrade to cmux Pro", bundle: .module),
                keywords: ["pro", "billing", "subscription"], category: .settings, symbol: "star.circle",
                surfaces: [.palette, .menu]
            ),
            ActionDescriptor(
                id: "palette.welcomeChecklist",
                title: String(localized: "action.palette.welcomeChecklist", defaultValue: "Welcome Checklist", bundle: .module),
                keywords: ["onboarding", "getting started"], category: .settings, symbol: "sparkles",
                surfaces: [.palette, .menu]
            ),
            ActionDescriptor(
                id: "sendFeedback",
                title: String(localized: "action.sendFeedback", defaultValue: "Send Feedback", bundle: .module),
                keywords: ["bug", "report", "contact"], category: .settings, symbol: "envelope",
                surfaces: [.keyboard, .menu]
            ),
            ActionDescriptor(
                id: "help.featureFlags",
                title: String(localized: "action.help.featureFlags", defaultValue: "Feature Flags", bundle: .module),
                keywords: ["experiments", "beta"], category: .settings, symbol: "flag", surfaces: [.menu]
            ),
            ActionDescriptor(
                id: "help.documentation",
                title: String(localized: "action.help.documentation", defaultValue: "cmux Documentation…", bundle: .module),
                keywords: ["docs", "help", "manual"], category: .settings, symbol: "book", surfaces: [.menu],
                input: .list
            ),
            ActionDescriptor(
                id: "appearance.density.compact",
                title: String(localized: "action.appearance.density.compact", defaultValue: "Use Compact Density", bundle: .module),
                keywords: ["density", "compact", "dense", "appearance", "size"], category: .settings,
                symbol: "rectangle.compress.vertical", surfaces: [.palette]
            ),
            ActionDescriptor(
                id: "appearance.density.comfortable",
                title: String(localized: "action.appearance.density.comfortable", defaultValue: "Use Comfortable Density", bundle: .module),
                keywords: ["density", "comfortable", "spacious", "appearance", "size"], category: .settings,
                symbol: "rectangle.expand.vertical", surfaces: [.palette]
            ),
            ActionDescriptor(
                id: "appearance.interfaceSize.increase",
                title: String(localized: "action.appearance.interfaceSize.increase", defaultValue: "Increase Interface Size", bundle: .module),
                keywords: ["appearance", "font", "chrome", "bigger", "zoom"], category: .settings,
                symbol: "plus.magnifyingglass", surfaces: [.palette]
            ),
            ActionDescriptor(
                id: "appearance.interfaceSize.decrease",
                title: String(localized: "action.appearance.interfaceSize.decrease", defaultValue: "Decrease Interface Size", bundle: .module),
                keywords: ["appearance", "font", "chrome", "smaller", "zoom"], category: .settings,
                symbol: "minus.magnifyingglass", surfaces: [.palette]
            ),
            ActionDescriptor(
                id: "appearance.interfaceSize.reset",
                title: String(localized: "action.appearance.interfaceSize.reset", defaultValue: "Reset Interface Size", bundle: .module),
                keywords: ["appearance", "font", "chrome", "default"], category: .settings, symbol: "textformat.size",
                surfaces: [.palette]
            ),
        ]
    }
}
