// Catalog rows for one domain. Titles live in Localizable.xcstrings (en, ja).

nonisolated enum SettingsActionCatalog: ActionCatalogGroup {
    static func descriptors() -> [ActionDescriptor] {
        var actions: [ActionDescriptor] = [
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
                keywords: ["config", "settings", "file", "edit", "ghostty"], category: .settings, symbol: "doc.plaintext",
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
                // installs cmux-next beside it and its toast offers Replace.
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
                id: "palette.restartServer",
                title: String(localized: "action.palette.restartServer", defaultValue: "Restart cmux-tui…", bundle: .module),
                keywords: ["server", "daemon", "cmux-tui", "restart", "update", "new features", "protocol"],
                category: .settings, symbol: "arrow.clockwise.circle",
                surfaces: [.palette], cliName: "settings restart-server"
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
                keywords: ["changelog", "release notes", "update", "new", "whats new"], category: .settings, symbol: "sparkles",
                surfaces: [.palette, .menu], cliName: "settings whats-new", mainMenu: .help
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
            // Drop back to the build before the last update (kept by `updates.keepPreviousVersions`):
            // refused, with the reason, when nothing is kept or a store holds data the kept build
            // cannot read. Relaunches, so every entrypoint confirms first.
            ActionDescriptor(
                id: "updates.rollback",
                title: String(localized: "action.updates.rollback", defaultValue: "Roll Back to Previous Version…", bundle: .module),
                keywords: ["rollback", "roll back", "downgrade", "previous", "revert", "update", "nightly", "drop back"],
                category: .settings, symbol: "arrow.uturn.backward.circle", surfaces: [.palette, .menu],
                cliName: "settings rollback-update", mainMenu: .app, destructive: true
            ),
            ActionDescriptor(
                id: "palette.pro.upgrade",
                title: String(localized: "action.palette.pro.upgrade", defaultValue: "Upgrade to cmux Pro", bundle: .module),
                keywords: ["pro", "billing", "subscription"], category: .settings, symbol: "star.circle",
                surfaces: [.palette, .menu], cliName: "settings upgrade-to-pro", mainMenu: .app
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
                id: "appearance.animations.newTab.toggle",
                title: String(localized: "action.appearance.animations.newTab.toggle", defaultValue: "Toggle New Tab Animations", bundle: .module),
                keywords: ["animation", "motion", "tab", "new tab", "appearance"], category: .settings,
                symbol: "plus.rectangle.on.rectangle", surfaces: [.palette], cliName: "settings toggle-new-tab-animations"
            ),
            ActionDescriptor(
                id: "appearance.animations.newWorkspace.toggle",
                title: String(localized: "action.appearance.animations.newWorkspace.toggle", defaultValue: "Toggle New Workspace Animations", bundle: .module),
                keywords: ["animation", "motion", "workspace", "sidebar", "appearance"], category: .settings,
                symbol: "sidebar.left", surfaces: [.palette], cliName: "settings toggle-new-workspace-animations"
            ),
            ActionDescriptor(
                id: "appearance.animations.toggle",
                title: String(localized: "action.appearance.animations.toggle", defaultValue: "Toggle All Animations", bundle: .module),
                keywords: ["animation", "motion", "appearance", "no animations", "disable", "reduce motion", "instant"], category: .settings,
                symbol: "sparkles", surfaces: [.palette], cliName: "settings toggle-all-animations"
            ),
            ActionDescriptor(
                id: "appearance.animations.sidebar.toggle",
                title: String(localized: "action.appearance.animations.sidebar.toggle", defaultValue: "Toggle Sidebar Animations", bundle: .module),
                keywords: ["animation", "motion", "appearance", "sidebar", "row", "group", "reorder"], category: .settings,
                symbol: "sidebar.left", surfaces: [.palette], cliName: "settings toggle-sidebar-animations"
            ),
            ActionDescriptor(
                id: "appearance.animations.tabs.toggle",
                title: String(localized: "action.appearance.animations.tabs.toggle", defaultValue: "Toggle Tab Animations", bundle: .module),
                keywords: ["animation", "motion", "appearance", "tab", "tab bar"], category: .settings,
                symbol: "rectangle.split.3x1", surfaces: [.palette], cliName: "settings toggle-tab-animations"
            ),
            ActionDescriptor(
                id: "appearance.animations.panes.toggle",
                title: String(localized: "action.appearance.animations.panes.toggle", defaultValue: "Toggle Pane and Window Animations", bundle: .module),
                keywords: ["animation", "motion", "appearance", "pane", "split", "zoom", "window"], category: .settings,
                symbol: "rectangle.split.2x1", surfaces: [.palette], cliName: "settings toggle-pane-and-window-animations"
            ),
            ActionDescriptor(
                id: "appearance.animations.overlays.toggle",
                title: String(localized: "action.appearance.animations.overlays.toggle", defaultValue: "Toggle Menu and Card Animations", bundle: .module),
                keywords: ["animation", "motion", "appearance", "menu", "popover", "palette", "toast", "card"], category: .settings,
                symbol: "menubar.rectangle", surfaces: [.palette], cliName: "settings toggle-menu-and-card-animations"
            ),
            ActionDescriptor(
                id: "appearance.animations.hoverCards.toggle",
                title: String(localized: "action.appearance.animations.hoverCards.toggle", defaultValue: "Toggle Hover Card Animations", bundle: .module),
                keywords: ["animation", "motion", "appearance", "hover card", "tooltip"], category: .settings,
                symbol: "rectangle.on.rectangle", surfaces: [.palette], cliName: "settings toggle-hover-card-animations"
            ),
            ActionDescriptor(
                id: "appearance.animations.home.toggle",
                title: String(localized: "action.appearance.animations.home.toggle", defaultValue: "Toggle Home and Chat Animations", bundle: .module),
                keywords: ["animation", "motion", "appearance", "home", "chief", "chat", "bubble"], category: .settings,
                symbol: "bubble.left.and.bubble.right", surfaces: [.palette], cliName: "settings toggle-home-and-chat-animations"
            ),
            ActionDescriptor(
                id: "appearance.animations.cursor.toggle",
                title: String(localized: "action.appearance.animations.cursor.toggle", defaultValue: "Toggle Agent Cursor Animations", bundle: .module),
                keywords: ["animation", "motion", "appearance", "cursor", "agent", "ripple"], category: .settings,
                symbol: "cursorarrow.motionlines", surfaces: [.palette], cliName: "settings toggle-agent-cursor-animations"
            ),
            ActionDescriptor(
                id: "appearance.animations.indicators.toggle",
                title: String(localized: "action.appearance.animations.indicators.toggle", defaultValue: "Toggle Spinner and Progress Animations", bundle: .module),
                keywords: ["animation", "motion", "appearance", "spinner", "progress", "pulse", "loading"], category: .settings,
                symbol: "progress.indicator", surfaces: [.palette], cliName: "settings toggle-spinner-and-progress-animations"
            ),
            ActionDescriptor(
                id: "appearance.animations.feedback.toggle",
                title: String(localized: "action.appearance.animations.feedback.toggle", defaultValue: "Toggle Highlight and Color Animations", bundle: .module),
                keywords: ["animation", "motion", "appearance", "hover", "highlight", "color", "theme"], category: .settings,
                symbol: "hand.point.up.left", surfaces: [.palette], cliName: "settings toggle-highlight-and-color-animations"
            ),
            ActionDescriptor(
                id: "appearance.animations.web.toggle",
                title: String(localized: "action.appearance.animations.web.toggle", defaultValue: "Toggle Web Page Animations", bundle: .module),
                keywords: ["animation", "motion", "appearance", "web", "page", "css"], category: .settings,
                symbol: "globe", surfaces: [.palette], cliName: "settings toggle-web-page-animations"
            ),
            ActionDescriptor(
                id: "appearance.animations.bounce.subtle",
                title: String(localized: "action.appearance.animations.bounce.subtle", defaultValue: "Use Bouncy Animations", bundle: .module),
                keywords: ["animation", "motion", "spring", "bounce", "bouncy", "appearance"], category: .settings,
                symbol: "arrow.up.and.down.and.sparkles", surfaces: [.palette], cliName: "settings use-bouncy-animations"
            ),
            ActionDescriptor(
                id: "appearance.animations.bounce.none",
                title: String(localized: "action.appearance.animations.bounce.none", defaultValue: "Use Animations Without Bounce", bundle: .module),
                keywords: ["animation", "motion", "spring", "bounce", "critically damped", "appearance"], category: .settings,
                symbol: "arrow.right.to.line", surfaces: [.palette], cliName: "settings use-animations-without-bounce"
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
            // Tab Overflow (`tabs.overflow`, cx-kp9b4): crowded strips shrink their tabs (the default) or
            // keep them wide and scroll. Settings changes with no object; no default shortcut.
            ActionDescriptor(
                id: "tabs.overflow.scroll",
                title: String(localized: "action.tabs.overflow.scroll", defaultValue: "Tabs: Use Scrolling Tabs", bundle: .module),
                keywords: ["tab", "tabs", "scroll", "scrolling", "overflow", "wide", "width", "many", "strip"], category: .settings,
                symbol: "arrow.left.and.right.square", surfaces: [.palette], cliName: "settings use-scrolling-tabs",
                surfacePlan: ActionSurfacePlan(cli: .offered, contextMenuExemption: .noObject)
            ),
            ActionDescriptor(
                id: "tabs.overflow.shrink",
                title: String(localized: "action.tabs.overflow.shrink", defaultValue: "Tabs: Use Shrinking Tabs", bundle: .module),
                keywords: ["tab", "tabs", "shrink", "shrinking", "overflow", "narrow", "width", "fit", "strip"], category: .settings,
                symbol: "arrow.right.and.line.vertical.and.arrow.left", surfaces: [.palette], cliName: "settings use-shrinking-tabs",
                surfacePlan: ActionSurfacePlan(cli: .offered, contextMenuExemption: .noObject)
            ),
            // Links (`browser.openLinksInCmuxBrowser`, cx-ir3z4): where a clicked link opens, from every
            // surface. Settings changes with no object; no default shortcut.
            ActionDescriptor(
                id: "links.openInCmuxBrowser",
                title: String(localized: "action.links.openInCmuxBrowser", defaultValue: "Links: Open in cmux Browser", bundle: .module),
                keywords: ["link", "links", "url", "browser", "embedded", "click", "terminal", "chat"], category: .settings,
                symbol: "globe", surfaces: [.palette], cliName: "settings open-links-in-cmux-browser",
                surfacePlan: ActionSurfacePlan(cli: .offered, contextMenuExemption: .noObject)
            ),
            ActionDescriptor(
                id: "links.openInDefaultBrowser",
                title: String(localized: "action.links.openInDefaultBrowser", defaultValue: "Links: Open in Default Browser", bundle: .module),
                keywords: ["link", "links", "url", "browser", "default", "external", "system", "safari", "chrome"], category: .settings,
                symbol: "arrow.up.forward.app", surfaces: [.palette], cliName: "settings open-links-in-default-browser",
                surfacePlan: ActionSurfacePlan(cli: .offered, contextMenuExemption: .noObject)
            ),
            // Sign-in pages (`browser.openSignInPagesInCmux`): a sign-in or device-code page opens in a
            // cmux tab whatever the link settings, or follows them. Settings changes with no object.
            ActionDescriptor(
                id: "links.signInPagesInCmux",
                title: String(localized: "action.links.signInPagesInCmux", defaultValue: "Sign-In Pages: Open in cmux Browser", bundle: .module),
                keywords: ["sign in", "login", "device", "code", "oauth", "auth", "passkey", "browser", "helium", "gh auth login"], category: .settings,
                symbol: "person.badge.key", surfaces: [.palette], cliName: "settings open-sign-in-pages-in-cmux",
                surfacePlan: ActionSurfacePlan(cli: .offered, contextMenuExemption: .noObject)
            ),
            ActionDescriptor(
                id: "links.signInPagesByLinkSettings",
                title: String(localized: "action.links.signInPagesByLinkSettings", defaultValue: "Sign-In Pages: Follow Link Settings", bundle: .module),
                keywords: ["sign in", "login", "device", "code", "oauth", "auth", "default browser", "external", "system"], category: .settings,
                symbol: "person.badge.key.fill", surfaces: [.palette], cliName: "settings sign-in-pages-follow-link-settings",
                surfacePlan: ActionSurfacePlan(cli: .offered, contextMenuExemption: .noObject)
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
            // Leo 2026-10-21: the lens is a toggle to see and feel before it is the default. Flips the
            // Debug choice `glass.lens` between Plain Glass (the default) and Lens, live, from the
            // palette or the Debug menu (DEV and NIGHTLY).
            ActionDescriptor(
                id: "appearance.glass.lens.toggle",
                title: String(localized: "action.appearance.glass.lens.toggle", defaultValue: "Toggle Liquid Glass Lens", bundle: .module),
                keywords: ["glass", "liquid glass", "lens", "refraction", "wallpaper", "plain glass", "appearance"],
                category: .settings, symbol: "drop", surfaces: [.palette, .menu], mainMenu: .debug, isDebugOnly: true,
                surfacePlan: ActionSurfacePlan(cli: .exempt(.devOnly), contextMenuExemption: .noObject)
            ),
            // The per-action budget's HUD (zero-latency.md, the budget contract): the newest action runs
            // and their perform-to-commit times, over-budget ones in red (Debug menu, DEV and NIGHTLY).
            ActionDescriptor(
                id: "debug.actionLatencyHUD",
                title: String(localized: "action.debug.actionLatencyHUD", defaultValue: "Toggle Action Latency HUD", bundle: .module),
                keywords: ["latency", "budget", "10 ms", "slow", "action", "hud", "perf", "frame", "debug"],
                category: .settings, symbol: "gauge.with.dots.needle.67percent", surfaces: [.palette, .menu], mainMenu: .debug,
                isDebugOnly: true,
                surfacePlan: ActionSurfacePlan(cli: .exempt(.devOnly), contextMenuExemption: .noObject)
            ),
            // Debug menu > Main-Thread Blocking (N) > Reset Counts (threading-model.md): zeroes the blocking
            // detector's per-site counts. `BlockingCallsMenu` places the row in its submenu, so no `mainMenu`.
            ActionDescriptor(
                id: "debug.blockingCalls.reset",
                title: String(localized: "action.debug.blockingCalls.reset", defaultValue: "Reset Main-Thread Blocking Counts",
                              bundle: .module),
                keywords: ["blocking", "main thread", "hang", "stall", "reset", "counts", "debug"],
                category: .settings, symbol: "arrow.counterclockwise", surfaces: [.palette, .menu], isDebugOnly: true,
                surfacePlan: ActionSurfacePlan(cli: .exempt(.devOnly), contextMenuExemption: .noObject)
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
            // Ctrl-Shift-Cmd-= / - / 0 scale all app text (Lawrence 2026-10-19: "for changing font size we
            // should do Command+Shift+Control++ and -"); Ctrl-Cmd-= is Equalize Splits, as in Ghostty.
            ActionDescriptor(
                id: "appearance.uiScale.increase",
                title: String(localized: "action.appearance.uiScale.increase", defaultValue: "Increase Interface Scale", bundle: .module),
                keywords: ["appearance", "scale", "chrome", "bigger", "zoom"],
                defaultShortcut: Shortcut("=", modifiers: [.control, .shift, .command]), category: .settings,
                symbol: "plus.magnifyingglass", surfaces: [.palette, .keyboard, .menu], cliName: "settings increase-interface-scale", mainMenu: .view
            ),
            ActionDescriptor(
                id: "appearance.uiScale.decrease",
                title: String(localized: "action.appearance.uiScale.decrease", defaultValue: "Decrease Interface Scale", bundle: .module),
                keywords: ["appearance", "scale", "chrome", "smaller", "zoom"],
                defaultShortcut: Shortcut("-", modifiers: [.control, .shift, .command]), category: .settings,
                symbol: "minus.magnifyingglass", surfaces: [.palette, .keyboard, .menu], cliName: "settings decrease-interface-scale", mainMenu: .view
            ),
            ActionDescriptor(
                id: "appearance.uiScale.reset",
                title: String(localized: "action.appearance.uiScale.reset", defaultValue: "Reset Interface Scale", bundle: .module),
                keywords: ["appearance", "scale", "chrome", "default", "zoom"],
                defaultShortcut: Shortcut("0", modifiers: [.control, .shift, .command]), category: .settings,
                symbol: "1.magnifyingglass", surfaces: [.palette, .keyboard, .menu], cliName: "settings reset-interface-scale", mainMenu: .view
            ),
        ]
        // A CLI or agent run answers with the result: the feed's newest build, or whether the
        // update installs and why not (UpdateHandlers+Results.swift).
        let waitsForResult: Set<ActionID> = ["palette.checkForUpdates", "palette.applyUpdateIfAvailable", "palette.attemptUpdate"]
        for index in actions.indices where waitsForResult.contains(actions[index].id) {
            actions[index].waitsForResult = true
        }
        return actions
    }
}
