// Catalog rows for one domain. Titles live in Localizable.xcstrings (en, ja).

nonisolated extension ActionCatalog {
    static func settingsActions() -> [ActionDescriptor] {
        [
            ActionDescriptor(
                id: "reloadConfiguration",
                title: String(localized: "action.reloadConfiguration", defaultValue: "Reload Configuration", bundle: .module),
                keywords: ["config", "cmux.json", "ghostty"],
                defaultShortcut: Shortcut(",", modifiers: [.command, .shift]), category: .settings,
                symbol: "arrow.clockwise", surfaces: [.keyboard, .menu], cliName: "settings reload-configuration",
                mainMenu: .app
            ),
            ActionDescriptor(
                id: "palette.openCmuxSettingsFile",
                title: String(localized: "action.palette.openCmuxSettingsFile", defaultValue: "Open cmux.json", bundle: .module),
                keywords: ["config", "settings", "file"], category: .settings, symbol: "curlybraces",
                surfaces: [.palette, .menu], cliName: "settings open-json", mainMenu: .app
            ),
            ActionDescriptor(
                id: "palette.openGhosttySettings",
                title: String(localized: "action.palette.openGhosttySettings", defaultValue: "Open Ghostty Config", bundle: .module),
                keywords: ["config", "settings", "file"], category: .settings, symbol: "doc.plaintext",
                surfaces: [.palette, .menu], cliName: "settings open-ghostty-config", mainMenu: .app
            ),
            ActionDescriptor(
                id: "palette.makeDefaultBrowser",
                title: String(localized: "action.palette.makeDefaultBrowser", defaultValue: "Make cmux the Default Browser", bundle: .module),
                keywords: ["default", "browser", "handler", "links"], category: .settings, symbol: "globe",
                surfaces: [.palette, .menu], cliName: "settings make-default-browser", mainMenu: .app
            ),
            ActionDescriptor(
                id: "palette.makeDefaultTerminal",
                title: String(localized: "action.palette.makeDefaultTerminal", defaultValue: "Make cmux the Default Terminal", bundle: .module),
                keywords: ["default", "handler"], category: .settings, symbol: "checkmark.seal",
                surfaces: [.palette, .menu], cliName: "settings make-default-terminal", mainMenu: .app
            ),
            ActionDescriptor(
                id: "palette.toggleSetting",
                title: String(localized: "action.palette.toggleSetting", defaultValue: "Toggle Setting…", bundle: .module),
                keywords: ["preferences", "enable", "disable"], category: .settings, symbol: "switch.2",
                surfaces: [.palette], arguments: [CatalogArgument.settingString, CatalogArgument.onBool.optional],
                cliName: "settings toggle-setting"
            ),
            ActionDescriptor(
                id: "palette.shortcutKeymap",
                title: String(localized: "action.palette.shortcutKeymap", defaultValue: "Base Keymap…", bundle: .module),
                keywords: ["shortcuts", "preset", "vim"], category: .settings, symbol: "keyboard.badge.eye",
                surfaces: [.palette], arguments: [CatalogArgument.keymapString], cliName: "settings base-keymap"
            ),
            ActionDescriptor(
                id: "palette.searchShortcuts",
                title: String(localized: "action.palette.searchShortcuts", defaultValue: "Search Keyboard Shortcuts…", bundle: .module),
                keywords: ["shortcuts", "keybindings", "hotkeys", "help"], category: .settings, symbol: "keyboard",
                surfaces: [.palette, .menu], cliName: "settings search-keyboard-shortcuts", mainMenu: .help
            ),
            ActionDescriptor(
                id: "palette.installCLI",
                title: String(localized: "action.palette.installCLI", defaultValue: "Install cmux CLI in PATH", bundle: .module),
                keywords: ["command line", "shell"], category: .settings, symbol: "terminal", surfaces: [.palette],
                cliName: "settings install-cli-in-path"
            ),
            ActionDescriptor(
                id: "palette.uninstallCLI",
                title: String(localized: "action.palette.uninstallCLI", defaultValue: "Uninstall cmux CLI from PATH", bundle: .module),
                keywords: ["command line", "shell"], category: .settings, symbol: "terminal.fill", surfaces: [.palette],
                cliName: "settings uninstall-cli-from-path"
            ),
            ActionDescriptor(
                id: "palette.restartSocketListener",
                title: String(localized: "action.palette.restartSocketListener", defaultValue: "Restart CLI Listener", bundle: .module),
                keywords: ["socket", "cli"], category: .settings, symbol: "antenna.radiowaves.left.and.right",
                surfaces: [.palette], cliName: "settings restart-cli-listener"
            ),
            ActionDescriptor(
                id: "palette.checkForUpdates",
                title: String(localized: "action.palette.checkForUpdates", defaultValue: "Check for Updates…", bundle: .module),
                keywords: ["update", "version", "sparkle"], category: .settings, symbol: "arrow.down.circle",
                surfaces: [.palette, .menu], cliName: "settings check-for-updates", mainMenu: .app
            ),
            ActionDescriptor(
                id: "palette.applyUpdateIfAvailable",
                title: String(localized: "action.palette.applyUpdateIfAvailable", defaultValue: "Install Available Update", bundle: .module),
                keywords: ["update", "install"], category: .settings, symbol: "arrow.down.circle.fill",
                surfaces: [.palette, .menu], cliName: "settings install-available-update", mainMenu: .app
            ),
            ActionDescriptor(
                id: "palette.attemptUpdate",
                title: String(localized: "action.palette.attemptUpdate", defaultValue: "Attempt Update", bundle: .module),
                keywords: ["update", "retry"], category: .settings, symbol: "arrow.triangle.2.circlepath",
                surfaces: [.palette], cliName: "settings attempt-update"
            ),
            ActionDescriptor(
                id: "palette.switchAppChannel",
                title: String(localized: "action.palette.switchAppChannel", defaultValue: "Switch Update Channel…", bundle: .module),
                keywords: ["nightly", "beta", "stable", "channel"], category: .settings,
                symbol: "antenna.radiowaves.left.and.right.circle", surfaces: [.palette, .menu],
                arguments: [CatalogArgument.channelChoice], cliName: "settings switch-update-channel", mainMenu: .app
            ),
            ActionDescriptor(
                id: "palette.pro.upgrade",
                title: String(localized: "action.palette.pro.upgrade", defaultValue: "Upgrade to cmux Pro", bundle: .module),
                keywords: ["pro", "billing", "subscription"], category: .settings, symbol: "star.circle",
                surfaces: [.palette, .menu], cliName: "settings upgrade-to-pro", mainMenu: .app
            ),
            ActionDescriptor(
                id: "palette.welcomeChecklist",
                title: String(localized: "action.palette.onboarding", defaultValue: "Onboarding…", bundle: .module),
                keywords: ["onboarding", "getting started", "welcome", "import", "theme", "default browser", "tour"],
                category: .settings, symbol: "sparkles",
                surfaces: [.palette, .menu], cliName: "settings onboarding", mainMenu: .app
            ),
            ActionDescriptor(
                id: "sendFeedback",
                title: String(localized: "action.sendFeedback", defaultValue: "Send Feedback", bundle: .module),
                keywords: ["bug", "report", "contact"], category: .settings, symbol: "envelope",
                surfaces: [.keyboard, .menu], cliName: "settings send-feedback", mainMenu: .help
            ),
            ActionDescriptor(
                id: "help.featureFlags",
                title: String(localized: "action.help.featureFlags", defaultValue: "Feature Flags", bundle: .module),
                keywords: ["experiments", "beta"], category: .settings, symbol: "flag", surfaces: [.menu],
                cliName: "settings feature-flags", mainMenu: .help
            ),
            ActionDescriptor(
                id: "help.documentation",
                title: String(localized: "action.help.documentation", defaultValue: "cmux Documentation…", bundle: .module),
                keywords: ["docs", "help", "manual"], category: .settings, symbol: "book", surfaces: [.menu],
                arguments: [CatalogArgument.topicString], cliName: "settings documentation", mainMenu: .help
            ),
            ActionDescriptor(
                id: "appearance.density.compact",
                title: String(localized: "action.appearance.density.compact", defaultValue: "Use Compact Density", bundle: .module),
                keywords: ["density", "compact", "dense", "appearance", "size"], category: .settings,
                symbol: "rectangle.compress.vertical", surfaces: [.palette], cliName: "settings use-compact-density"
            ),
            ActionDescriptor(
                id: "appearance.density.comfortable",
                title: String(localized: "action.appearance.density.comfortable", defaultValue: "Use Comfortable Density", bundle: .module),
                keywords: ["density", "comfortable", "spacious", "appearance", "size"], category: .settings,
                symbol: "rectangle.expand.vertical", surfaces: [.palette], cliName: "settings use-comfortable-density"
            ),
            ActionDescriptor(
                id: "appearance.animationSpeed.fast",
                title: String(localized: "action.appearance.animationSpeed.fast", defaultValue: "Use Fast Animations", bundle: .module),
                keywords: ["animation", "motion", "speed", "fast", "snappy", "appearance"], category: .settings,
                symbol: "hare", surfaces: [.palette], cliName: "settings use-fast-animations"
            ),
            ActionDescriptor(
                id: "appearance.animationSpeed.normal",
                title: String(localized: "action.appearance.animationSpeed.normal", defaultValue: "Use Normal Animations", bundle: .module),
                keywords: ["animation", "motion", "speed", "normal", "slow", "appearance"], category: .settings,
                symbol: "tortoise", surfaces: [.palette], cliName: "settings use-normal-animations"
            ),
            ActionDescriptor(
                id: "appearance.animationSpeed.off",
                title: String(localized: "action.appearance.animationSpeed.off", defaultValue: "Turn Off Animations", bundle: .module),
                keywords: ["animation", "motion", "speed", "off", "disable", "reduce", "appearance"], category: .settings,
                symbol: "figure.stand", surfaces: [.palette], cliName: "settings turn-off-animations"
            ),
            ActionDescriptor(
                id: "browser.defaultEngine.chromium",
                title: String(localized: "action.browser.defaultEngine.chromium", defaultValue: "Use Chromium for New Browser Tabs", bundle: .module),
                keywords: ["browser", "engine", "default", "chrome", "chromium", "cef"], category: .settings,
                symbol: "circle.circle", surfaces: [.palette], cliName: "settings use-chromium-by-default"
            ),
            ActionDescriptor(
                id: "browser.defaultEngine.webkit",
                title: String(localized: "action.browser.defaultEngine.webkit", defaultValue: "Use WebKit for New Browser Tabs", bundle: .module),
                keywords: ["browser", "engine", "default", "safari", "webkit"], category: .settings,
                symbol: "safari", surfaces: [.palette], cliName: "settings use-webkit-by-default"
            ),
            ActionDescriptor(
                id: "appearance.paneBorder.toggle",
                title: String(localized: "action.appearance.paneBorder.toggle", defaultValue: "Toggle Pane Borders", bundle: .module),
                keywords: ["border", "outline", "hairline", "pane", "appearance", "layout"], category: .settings,
                symbol: "square.dashed", surfaces: [.palette], cliName: "settings toggle-pane-border"
            ),
            ActionDescriptor(
                id: "appearance.panePadding.toggle",
                title: String(localized: "action.appearance.panePadding.toggle", defaultValue: "Toggle Pane Padding", bundle: .module),
                keywords: ["padding", "gap", "inset", "edge to edge", "pane", "appearance", "layout"], category: .settings,
                symbol: "rectangle.inset.filled", surfaces: [.palette], cliName: "settings toggle-pane-padding"
            ),
            ActionDescriptor(
                id: "appearance.paneCorners.toggle",
                title: String(localized: "action.appearance.paneCorners.toggle", defaultValue: "Toggle Rounded Pane Corners", bundle: .module),
                keywords: ["corner", "radius", "rounded", "square", "pane", "appearance", "layout"], category: .settings,
                symbol: "square.on.square", surfaces: [.palette], cliName: "settings toggle-pane-corners"
            ),
            ActionDescriptor(
                id: "layout.centerFocusedColumn.never",
                title: String(localized: "action.layout.centerFocusedColumn.never", defaultValue: "Scroll Columns Minimally", bundle: .module),
                keywords: ["niri", "column", "center", "scroll", "reveal", "never", "minimal", "layout"], category: .settings,
                symbol: "arrow.left.and.right", surfaces: [.palette], cliName: "settings scroll-columns-minimally"
            ),
            ActionDescriptor(
                id: "layout.centerFocusedColumn.always",
                title: String(localized: "action.layout.centerFocusedColumn.always", defaultValue: "Always Center Focused Column", bundle: .module),
                keywords: ["niri", "column", "center", "scroll", "always", "layout"], category: .settings,
                symbol: "align.horizontal.center", surfaces: [.palette], cliName: "settings always-center-focused-column"
            ),
            ActionDescriptor(
                id: "layout.centerFocusedColumn.onOverflow",
                title: String(localized: "action.layout.centerFocusedColumn.onOverflow", defaultValue: "Center Focused Column on Overflow", bundle: .module),
                keywords: ["niri", "column", "center", "scroll", "overflow", "layout"], category: .settings,
                symbol: "align.horizontal.center.fill", surfaces: [.palette], cliName: "settings center-focused-column-on-overflow"
            ),
            ActionDescriptor(
                id: "focusRing.toggle",
                title: String(localized: "action.focusRing.toggle", defaultValue: "Toggle Focus Ring", bundle: .module),
                keywords: ["focus", "ring", "outline", "highlight", "pane", "appearance"], category: .settings,
                symbol: "square.dashed.inset.filled", surfaces: [.palette], cliName: "settings toggle-focus-ring"
            ),
            ActionDescriptor(
                id: "focusRing.style.ring",
                title: String(localized: "action.focusRing.style.ring", defaultValue: "Use Ring Focus Style", bundle: .module),
                keywords: ["focus", "ring", "outline", "stroke", "pane", "appearance"], category: .settings,
                symbol: "square", surfaces: [.palette], cliName: "settings use-ring-focus-style"
            ),
            ActionDescriptor(
                id: "focusRing.style.glow",
                title: String(localized: "action.focusRing.style.glow", defaultValue: "Use Glow Focus Style", bundle: .module),
                keywords: ["focus", "glow", "inner", "shadow", "pane", "appearance"], category: .settings,
                symbol: "square.fill.on.square", surfaces: [.palette], cliName: "settings use-glow-focus-style"
            ),
            ActionDescriptor(
                id: "focusRing.singlePane.toggle",
                title: String(localized: "action.focusRing.singlePane.toggle", defaultValue: "Toggle Focus Ring for a Single Pane", bundle: .module),
                keywords: ["focus", "ring", "single", "one", "pane", "appearance"], category: .settings,
                symbol: "square.inset.filled", surfaces: [.palette], cliName: "settings toggle-single-pane-focus-ring"
            ),
            ActionDescriptor(
                id: "appearance.paneBorderWidth.toggle",
                title: String(localized: "action.appearance.paneBorderWidth.toggle", defaultValue: "Toggle Thick Pane Borders", bundle: .module),
                keywords: ["border", "width", "thick", "thin", "hairline", "pane", "appearance", "layout"], category: .settings,
                symbol: "lineweight", surfaces: [.palette], cliName: "settings toggle-thick-pane-borders"
            ),
            ActionDescriptor(
                id: "appearance.paneBorderColor.reset",
                title: String(localized: "action.appearance.paneBorderColor.reset", defaultValue: "Use Theme Color for Pane Borders", bundle: .module),
                keywords: ["border", "color", "colour", "theme", "ghostty", "reset", "pane", "appearance", "layout"], category: .settings,
                symbol: "paintpalette", surfaces: [.palette], cliName: "settings use-theme-pane-border-color"
            ),
            ActionDescriptor(
                id: "appearance.titlebar.minimal",
                title: String(localized: "action.appearance.titlebar.minimal", defaultValue: "Use Minimal Titlebar", bundle: .module),
                keywords: ["titlebar", "title bar", "window", "compact", "hide", "drag", "appearance"], category: .settings,
                symbol: "macwindow", surfaces: [.palette], cliName: "settings use-minimal-titlebar"
            ),
            ActionDescriptor(
                id: "appearance.titlebar.standard",
                title: String(localized: "action.appearance.titlebar.standard", defaultValue: "Use Standard Titlebar", bundle: .module),
                keywords: ["titlebar", "title bar", "window", "workspace name", "show", "appearance"], category: .settings,
                symbol: "macwindow.badge.plus", surfaces: [.palette], cliName: "settings use-standard-titlebar"
            ),
            ActionDescriptor(
                id: "appearance.interfaceSize.increase",
                title: String(localized: "action.appearance.interfaceSize.increase", defaultValue: "Increase Interface Size", bundle: .module),
                keywords: ["appearance", "font", "chrome", "bigger", "zoom"], category: .settings,
                symbol: "plus.magnifyingglass", surfaces: [.palette], cliName: "settings increase-interface-size"
            ),
            ActionDescriptor(
                id: "appearance.interfaceSize.decrease",
                title: String(localized: "action.appearance.interfaceSize.decrease", defaultValue: "Decrease Interface Size", bundle: .module),
                keywords: ["appearance", "font", "chrome", "smaller", "zoom"], category: .settings,
                symbol: "minus.magnifyingglass", surfaces: [.palette], cliName: "settings decrease-interface-size"
            ),
            ActionDescriptor(
                id: "appearance.interfaceSize.reset",
                title: String(localized: "action.appearance.interfaceSize.reset", defaultValue: "Reset Interface Size", bundle: .module),
                keywords: ["appearance", "font", "chrome", "default"], category: .settings, symbol: "textformat.size",
                surfaces: [.palette], cliName: "settings reset-interface-size"
            ),
        ]
    }
}
