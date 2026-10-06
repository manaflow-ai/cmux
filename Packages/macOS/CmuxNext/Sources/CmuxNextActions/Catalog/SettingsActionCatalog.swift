// Catalog rows for one domain. Titles live in Localizable.xcstrings (en, ja).

nonisolated enum SettingsActionCatalog: ActionCatalogGroup {
    static func descriptors() -> [ActionDescriptor] {
        [
            ActionDescriptor(
                id: "reloadConfiguration",
                title: String(localized: "action.reloadConfiguration", defaultValue: "Reload Configuration", bundle: .module),
                keywords: ["config", "cmux-next.json", "ghostty"],
                defaultShortcut: Shortcut(",", modifiers: [.command, .shift]), category: .settings,
                symbol: "arrow.clockwise", surfaces: [.keyboard, .menu], cliName: "settings reload-configuration",
                mainMenu: .app
            ),
            ActionDescriptor(
                id: "palette.openCmuxSettingsFile",
                title: String(localized: "action.palette.openCmuxSettingsFile", defaultValue: "Open cmux-next.json", bundle: .module),
                keywords: ["config", "settings", "cmux-next.json", "file"], category: .settings, symbol: "curlybraces",
                surfaces: [.palette, .menu], cliName: "settings open-json", mainMenu: .app
            ),
            ActionDescriptor(
                id: "palette.openGhosttySettings",
                title: String(localized: "action.palette.openGhosttySettings", defaultValue: "Open Ghostty Config", bundle: .module),
                keywords: ["config", "settings", "file"], category: .settings, symbol: "doc.plaintext",
                surfaces: [.palette, .menu], cliName: "settings open-ghostty-config", mainMenu: .app
            ),
            // R92 diagnostics: Settings > Terminal lists the Ghostty lines cmux
            // does not apply. The CLI prints the same list (`cmux ghostty
            // diagnostics`, the app's `ghostty.diagnostics`).
            ActionDescriptor(
                id: "ghostty.showDiagnostics",
                title: String(localized: "action.ghostty.showDiagnostics", defaultValue: "Show Ghostty Config Diagnostics", bundle: .module),
                keywords: ["ghostty", "config", "diagnostics", "unsupported", "keybind", "problems"], category: .settings,
                symbol: "exclamationmark.triangle", surfaces: [.palette]
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
                keywords: ["shortcuts", "preset", "iterm", "iterm2", "terminal", "tmux", "keybindings"], category: .settings,
                symbol: "keyboard.badge.eye", surfaces: [.palette], arguments: [CatalogArgument.keymapChoice], cliName: "settings base-keymap"
            ),
            ActionDescriptor(
                id: "palette.searchShortcuts",
                title: String(localized: "action.palette.searchShortcuts", defaultValue: "Search Keyboard Shortcuts…", bundle: .module),
                keywords: ["shortcuts", "keybindings", "hotkeys", "help"], category: .settings, symbol: "keyboard",
                surfaces: [.palette, .menu], cliName: "settings search-keyboard-shortcuts", mainMenu: .help
            ),
            // The Keyboard Shortcuts editor (R59), a React page tab; no
            // default key (defaults do not change, K1).
            ActionDescriptor(
                id: "keybindings.open",
                title: String(localized: "action.keybindings.open", defaultValue: "Open Keyboard Shortcuts", bundle: .module),
                keywords: ["shortcuts", "keybindings", "keys", "rebind", "chords", "when", "hotkeys"], category: .settings,
                symbol: "keyboard", surfaces: [.palette, .keyboard], cliName: "settings keyboard-shortcuts",
                surfacePlan: ActionSurfacePlan(cli: .offered, contextMenuExemption: .noObject)
            ),
            // DEV and NIGHTLY only (`DevTools`); CLI verb for the Rust CLI:
            // `cmux debug open-settings`.
            ActionDescriptor(
                id: "openDebugSettings",
                title: String(localized: "action.openDebugSettings", defaultValue: "Open Debug Settings", bundle: .module),
                keywords: ["debug", "tunables", "tune", "developer", "overlay", "motion", "metrics"], category: .settings,
                symbol: "slider.horizontal.3", surfaces: [.palette], cliName: "debug open-settings", isDebugOnly: true
            ),
            ActionDescriptor(
                id: "palette.installCLI",
                title: String(localized: "action.palette.installCLI", defaultValue: "Install cmux CLI in PATH", bundle: .module),
                keywords: ["command line", "shell"], category: .settings, symbol: "terminal", surfaces: [.palette],
                // Another app's `cmux` at /usr/local/bin is never replaced
                // silently: `--replace` replaces it, `--cmux_next` installs
                // /usr/local/bin/cmux-next beside it; without either the app
                // asks.
                arguments: [
                    ActionArgument(name: "replace",
                                   title: String(localized: "argument.installCLI.replace", defaultValue: "Replace Another App's cmux", bundle: .module),
                                   kind: .bool, isRequired: false),
                    ActionArgument(name: "cmux_next",
                                   title: String(localized: "argument.installCLI.cmuxNext", defaultValue: "Install as cmux-next", bundle: .module),
                                   kind: .bool, isRequired: false),
                ],
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
                id: "updates.whatsNew",
                title: String(localized: "action.updates.whatsNew", defaultValue: "What's New in cmux", bundle: .module),
                keywords: ["changelog", "release notes", "update", "new"], category: .settings, symbol: "sparkles",
                surfaces: [.palette, .menu], cliName: "settings whats-new", mainMenu: .app
            ),
            ActionDescriptor(
                id: "announcements.show",
                title: String(localized: "action.announcements.show", defaultValue: "Show Announcements", bundle: .module),
                keywords: ["announcements", "news", "cards"], category: .settings, symbol: "megaphone",
                surfaces: [.palette], cliName: "settings show-announcements"
            ),
            ActionDescriptor(
                id: "announcements.hide",
                title: String(localized: "action.announcements.hide", defaultValue: "Hide Announcements", bundle: .module),
                keywords: ["announcements", "news", "cards"], category: .settings, symbol: "megaphone",
                surfaces: [.palette], cliName: "settings hide-announcements"
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
                id: "palette.importClassicSessions",
                title: String(localized: "action.palette.importClassicSessions", defaultValue: "Import Classic cmux Sessions…", bundle: .module),
                keywords: ["classic", "session", "workspace", "restore", "import"], category: .settings, symbol: "arrow.down.doc",
                surfaces: [.palette, .menu], cliName: "settings import-classic-sessions"
            ),
            ActionDescriptor(
                id: "importAndSync.show",
                title: String(localized: "action.importAndSync.show", defaultValue: "Import and Sync…", bundle: .module),
                keywords: ["import", "sync", "classic", "session", "workspace", "chat", "onboarding"], category: .settings,
                symbol: "square.and.arrow.down", surfaces: [.palette],
                surfacePlan: ActionSurfacePlan(cli: .exempt(.guiOnly), contextMenuExemption: .guiOnly)
            ),
            ActionDescriptor(
                id: "palette.onboardingGallery",
                title: String(localized: "action.palette.onboardingGallery", defaultValue: "Onboarding Gallery", bundle: .module),
                keywords: ["onboarding", "variants", "design", "gallery"], category: .settings, symbol: "square.grid.3x3",
                surfaces: [.palette], cliName: "settings onboarding-gallery", isDebugOnly: true
            ),
            ActionDescriptor(
                id: "sendFeedback",
                title: String(localized: "action.sendFeedback", defaultValue: "Send Feedback", bundle: .module),
                keywords: ["bug", "report", "contact"], category: .settings, symbol: "envelope",
                surfaces: [.keyboard, .menu], cliName: "settings send-feedback", mainMenu: .help
            ),
            // Every entrypoint (Help menu, palette, `cmux settings show-crash-logs`,
            // the restart notice) opens the newest crash
            // log in TextEdit (CrashRecoveryService.showCrashLogs).
            ActionDescriptor(
                id: "help.showCrashLogs",
                title: String(localized: "action.help.showCrashLogs", defaultValue: "Show Crash Logs", bundle: .module),
                keywords: ["crash", "report", "ips", "log", "diagnostics", "textedit"], category: .settings,
                symbol: "doc.text.magnifyingglass", surfaces: [.palette, .menu], cliName: "settings show-crash-logs",
                mainMenu: .help
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
                keywords: ["column", "center", "scroll", "reveal", "never", "minimal", "layout"], category: .settings,
                symbol: "arrow.left.and.right", surfaces: [.palette], cliName: "settings scroll-columns-minimally"
            ),
            ActionDescriptor(
                id: "layout.centerFocusedColumn.always",
                title: String(localized: "action.layout.centerFocusedColumn.always", defaultValue: "Always Center Focused Column", bundle: .module),
                keywords: ["column", "center", "scroll", "always", "layout"], category: .settings,
                symbol: "align.horizontal.center", surfaces: [.palette], cliName: "settings always-center-focused-column"
            ),
            ActionDescriptor(
                id: "layout.centerFocusedColumn.onOverflow",
                title: String(localized: "action.layout.centerFocusedColumn.onOverflow", defaultValue: "Center Focused Column on Overflow", bundle: .module),
                keywords: ["column", "center", "scroll", "overflow", "layout"], category: .settings,
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
                id: "appearance.customize",
                title: String(localized: "action.appearance.customize", defaultValue: "Customize Appearance…", bundle: .module),
                keywords: ["appearance", "customize", "personalize", "theme", "colors", "background", "wallpaper", "font", "make it yours"],
                category: .settings, symbol: "paintbrush", surfaces: [.palette, .keyboard, .menu],
                cliName: "settings customize-appearance", mainMenu: .view
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
            ActionDescriptor(
                id: "appearance.uiScale.increase",
                title: String(localized: "action.appearance.uiScale.increase", defaultValue: "Increase Interface Scale", bundle: .module),
                keywords: ["appearance", "scale", "chrome", "bigger", "zoom"],
                defaultShortcut: Shortcut("=", modifiers: [.control, .command]), category: .settings,
                symbol: "plus.magnifyingglass", surfaces: [.palette, .keyboard, .menu], cliName: "settings increase-interface-scale", mainMenu: .view
            ),
            ActionDescriptor(
                id: "appearance.uiScale.decrease",
                title: String(localized: "action.appearance.uiScale.decrease", defaultValue: "Decrease Interface Scale", bundle: .module),
                keywords: ["appearance", "scale", "chrome", "smaller", "zoom"],
                defaultShortcut: Shortcut("-", modifiers: [.control, .command]), category: .settings,
                symbol: "minus.magnifyingglass", surfaces: [.palette, .keyboard, .menu], cliName: "settings decrease-interface-scale", mainMenu: .view
            ),
            ActionDescriptor(
                id: "appearance.uiScale.reset",
                title: String(localized: "action.appearance.uiScale.reset", defaultValue: "Reset Interface Scale", bundle: .module),
                keywords: ["appearance", "scale", "chrome", "default", "zoom"],
                defaultShortcut: Shortcut("0", modifiers: [.control, .command]), category: .settings,
                symbol: "1.magnifyingglass", surfaces: [.palette, .keyboard, .menu], cliName: "settings reset-interface-scale", mainMenu: .view
            ),
        ]
    }
}
