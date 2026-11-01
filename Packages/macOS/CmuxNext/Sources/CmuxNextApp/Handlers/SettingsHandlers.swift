import AppKit
import CmuxNextActions
import CmuxNextCompat
import CmuxNextErrorJournal
import CmuxNextSettings
import CmuxNextTerminal
import os

/// Settings and help actions (category `settings`, except appearance, see
/// `AppearanceHandlers`). Settings live in cmux-next.json (architecture.md 1), so
/// "open settings" opens that file and toggles write it; the watcher applies
/// the change. Update actions go to `UpdaterService` (UpdateHandlers), CLI
/// install to `CLIInstallHandlers`, Base Keymap to `KeymapHandlers`. Account
/// actions report that cmux-next has no implementation yet.
enum SettingsHandlers {
    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "app.actions")

    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        let previewTitle = SettingsSchema.descriptor(for: CmuxConfigSnapshot.previewFeaturesPath)?.title
            ?? CmuxConfigSnapshot.previewFeaturesPath.joined(separator: ".")
        registry.bind("palette.openCmuxSettingsFile", run: { _ in try openCmuxConfig(context) })
        registry.bind("palette.openGhosttySettings", run: { _ in try openGhosttyConfig(context) })
        // Showing the Settings tab is local and immediate: the effect is done on this turn.
        registry.bindEffect("settings.customizeMenus", requires: nil, effect: { invocation in
            try context.services.settingsWindow.show(section: nil, focus: invocation.allowsViewChange, route: "#/settings/menus")
            return .done
        })
        // R92: Settings > Terminal shows the Ghostty config diagnostics.
        registry.bind("ghostty.showDiagnostics", run: { invocation in
            try context.services.settingsWindow.show(section: .terminal, focus: invocation.allowsViewChange)
        })
        registry.bind("reloadConfiguration", run: { _ in
            let settings = try requireSettings(context)
            // The Ghostty config too: terminal colors and the chrome theme follow it.
            GhosttyRuntime.shared.reloadConfig()
            Task { await settings.reload() }
        })
        registry.bind("palette.toggleSetting", run: { invocation in try toggleSetting(invocation, context) })
        registry.bind("browser.defaultEngine.chromium", run: { _ in try setDefaultEngine(.chromium, context) })
        registry.bind("browser.defaultEngine.webkit", run: { _ in try setDefaultEngine(.webkit, context) })
        registry.bind("sendFeedback", run: { _ in try context.open(StaticURL.feedback.url) })
        registry.bind("help.showCrashLogs", run: { _ in context.services.crashRecovery.showCrashLogs() })
        // The menu bar menu's and the Help menu's community and support links (user 2026-10-27).
        let links: [(ActionID, StaticURL)] = [("help.troubleshooting", .support), ("help.discord", .discord), ("help.followOnX", .x), ("help.github", .github)]
        for (id, link) in links { registry.bindEffect(id, effect: { _ in openEffect(link.url, context) }) }
        registry.bindEffect("help.revealLogs", effect: { _ in revealLogs(context) })
        registry.bindEffect("help.copyLogs", effect: { _ in copyLogs(context) })
        HangReportsHandlers.bind(into: registry, context: context)
        registry.bind("help.documentation", run: { invocation in try context.open(documentationURL(topic: invocation["topic"]?.stringValue)) })
        registry.bind("app.shareCmux", run: { [weak services = context.services] _ in services.map(ShareCmuxPresenter.present) })
        // The changelog page's provider exists from launch, so a What's New tab that the session
        // restores (or Reopen Closed brings back) shows its title and page (cx-warpr).
        ChangelogPageTab.register(context.services)
        UpdateHandlers.bind(into: registry, updater: context.services.updater,
                            openWhatsNew: { [weak services = context.services] in services.map { WhatsNewPage.open($0) } ?? false },
                            stateDirectories: { [weak services = context.services] in services?.environment.daemonStateDirectories ?? [nil] })
        SetupGuidePage.bind(into: registry, services: context.services)
        OnboardingHandlers.bind(into: registry, context: context)
        // Keep the App Store out of menus and the palette while Labs is off (What's New is not
        // behind Labs). Compose this with the browser import gate installed above so unrelated
        // settings remain intact.
        let previousSettingOffReason = registry.settingOffReason
        registry.settingOffReason = { [weak services = context.services] id in
            if services?.settings?.snapshot.previewFeatures != true,
               id == "appStore.show" || id == "appStore.showInstalled" {
                return previewTitle
            }
            return previousSettingOffReason(id)
        }
        SessionMoveFromBuild.bind(into: registry, context: context)
        CLIInstallHandlers.bind(into: registry, context: context)
        KeymapHandlers.bind(into: registry, context: context)

        registry.bind("palette.restartSocketListener", run: { [weak services = context.services] _ in
            guard let restart = services?.restartControlListener else {
                throw ActionFailure(message: RefusalStrings.controlListenerNotRunning)
            }
            do { try restart() } catch {
                throw ActionFailure(message: RefusalStrings.controlListenerRestartFailed(String(describing: error)))
            }
        })
        registry.bind("help.featureFlags", run: { [weak services = context.services] invocation in
            guard let services else { return }
            try FeatureFlagsPage(services: services).open(invocation)
        })
        UpgradeToPro.bind(into: registry, context: context)
    }

    private static func openEffect(_ url: URL, _ context: AppActionContext) -> ActionEffect {
        do { try context.open(url) } catch { return .refused(RefusalStrings.describe(error)) }
        return .done
    }

    /// This build's error journal folder in Finder: every log it harvests (the app's, acpmux's, the Chief's, crashes).
    private static func revealLogs(_ context: AppActionContext) -> ActionEffect {
        NSWorkspace.shared.revealInBackground([logsDirectory(context)])
        return .done
    }

    /// The build, the system and the journal's problems of the last 3 days, as text on the clipboard (ErrorJournalReport).
    private static func copyLogs(_ context: AppActionContext) -> ActionEffect {
        let info = Bundle.main.infoDictionary ?? [:]
        let header = [
            "cmux \(info["CFBundleShortVersionString"] as? String ?? "?") (\(info["CFBundleVersion"] as? String ?? "?")) \(Bundle.main.bundleIdentifier ?? "?")",
            "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)",
            "Logs: \(logsDirectory(context).path)",
        ]
        guard let errors = context.services.errorJournal else {
            context.copy(ErrorJournalReport(header: header, entries: []).text())
            return .done
        }
        let journal = errors.journal, sources = errors.sources
        // action-wait-allow: the text exists only after the journal reads the logs and its entries off the main actor
        return .waiting(.fileSystem) {
            _ = await journal.harvest(sources)
            let entries = await journal.entries(ErrorQuery(since: Date().addingTimeInterval(-3 * 86_400), limit: 200))
            context.copy(ErrorJournalReport(header: header, entries: entries).text())
            return nil
        }
    }

    private static func logsDirectory(_ context: AppActionContext) -> URL {
        context.services.errorJournal?.journal.directory
            ?? ErrorJournalService.directory(bundleID: context.services.environment.launch.bundleID ?? Bundle.main.bundleIdentifier ?? "com.cmuxterm.app")
    }

    static func requireSettings(_ context: AppActionContext) throws -> SettingsController {
        guard let settings = context.services.settings else { throw ActionFailure(message: RefusalStrings.settingsNotLoaded) }
        return settings
    }

    /// Opens cmux-next.json in the default editor, creating an empty one first.
    static func openCmuxConfig(_ context: AppActionContext) throws {
        let url = context.services.settings?.file.url ?? CmuxConfigFile.defaultURL()
        try openCreatingIfMissing(url, contents: "{\n}\n", context)
    }

    /// Opens Ghostty's config (terminal fonts, colors, keybinds), which cmux
    /// reads for every terminal: the file Ghostty.app would open
    /// (`GhosttyRuntime.editableConfigPath`), so a user whose config is
    /// `config.ghostty` or in Application Support gets that file, not a new
    /// empty `~/.config/ghostty/config` (R92). It opens in cmux's code editor,
    /// editable: no app may claim a `.ghostty` file, and then the system open
    /// refused it ("Could not open file").
    private static func openGhosttyConfig(_ context: AppActionContext) throws {
        let environment = ProcessInfo.processInfo.environment
        let base = environment["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".config")
        let url = GhosttyRuntime.editableConfigPath().map { URL(fileURLWithPath: $0) }
            ?? base.appending(path: "ghostty/config")
        try createIfMissing(url, contents: "")
        // With no window to open it in, the system open is the only way; a refusal by the editor
        // already showed its reason, so it is not tried again.
        guard let pane = context.services.windows.active?.focusedPane else { return try context.open(url) }
        context.services.linkOpener.openFile(url, from: pane, asText: true)
    }

    private static func openCreatingIfMissing(_ url: URL, contents: String, _ context: AppActionContext) throws {
        try createIfMissing(url, contents: contents)
        try context.open(url)
    }

    private static func createIfMissing(_ url: URL, contents: String) throws {
        let manager = FileManager.default
        if !manager.fileExists(atPath: url.path) {
            try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(contents.utf8).write(to: url, options: .withoutOverwriting)
        }
    }

    /// Writes a boolean setting at a dotted cmux-next.json path. Without `on`,
    /// flips the value that applies now (a schema setting absent from the
    /// file flips its default). A schema setting that is not on/off is refused.
    private static func toggleSetting(_ invocation: ActionInvocation, _ context: AppActionContext) throws {
        let settings = try requireSettings(context)
        guard let setting = invocation["setting"]?.stringValue, !setting.isEmpty else {
            throw ActionFailure.invalidTarget(RefusalStrings.settingArgumentRequired)
        }
        let path = CmuxConfigFile.keyPath(from: setting)
        let descriptor = SettingsSchema.descriptor(for: path)
        if let descriptor, descriptor.kind != .toggle {
            throw ActionFailure.invalidTarget(RefusalStrings.settingNotToggle(descriptor.id))
        }
        try AppearanceHandlers.requireUnmanaged(path, context)
        let explicit = invocation["on"]?.boolValue
        let writer = SettingWriter(invocation.origin)
        Task {
            do {
                let root = try await settings.file.document()
                if let descriptor {
                    try await settings.setSetting(descriptor, to: .bool(explicit ?? descriptor.toggledValue(in: root) ?? true), by: writer)
                } else {
                    try await settings.set(.bool(explicit ?? !(root.value(at: path)?.boolValue ?? false)), at: path)
                }
            } catch {
                logger.error("toggle setting \(setting, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// `browser.defaultEngine`: applies at once (the next new tab uses it),
    /// then writes cmux-next.json; the watcher reapplies the same value.
    private static func setDefaultEngine(_ engine: BrowserDefaultEngine, _ context: AppActionContext) throws {
        try AppearanceHandlers.requireUnmanaged(BrowserDefaultEngine.configPath, context)
        context.services.cache.browserTabs.preference.defaultEngine = engine
        if engine == .chromium { context.services.chromiumWarmup.chromiumLikely(.defaultEngine) }
        guard let settings = context.services.settings else { return }
        Task {
            do { try await settings.setBrowserDefaultEngine(engine) } catch {
                logger.error("set browser.defaultEngine failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    static func documentationURL(topic: String?) -> URL {
        var url = StaticURL.documentation.url
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_/"))
        if let topic = topic?.trimmingCharacters(in: CharacterSet(charactersIn: "/ ")), !topic.isEmpty,
           topic.unicodeScalars.allSatisfy(allowed.contains) {
            url.append(path: topic)
        }
        return url
    }
}
