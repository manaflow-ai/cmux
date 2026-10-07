import AppKit
import CmuxNextActions
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
        registry.bind("palette.openCmuxSettingsFile", run: { _ in try openCmuxConfig(context) })
        registry.bind("palette.openGhosttySettings", run: { _ in try openGhosttyConfig(context) })
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
        registry.bind("sendFeedback", run: { _ in try context.open(URL(string: "https://github.com/manaflow-ai/cmux/issues/new")!) })
        registry.bind("help.showCrashLogs", run: { _ in context.services.crashRecovery.showCrashLogs() })
        registry.bind("help.documentation", run: { invocation in try context.open(documentationURL(topic: invocation["topic"]?.stringValue)) })
        UpdateHandlers.bind(into: registry, updater: context.services.updater,
                            openWhatsNew: { [weak services = context.services] in services.map { WhatsNewPage.open($0) } ?? false })
        OnboardingHandlers.bind(into: registry, context: context)
        CLIInstallHandlers.bind(into: registry, context: context)
        KeymapHandlers.bind(into: registry, context: context)

        let unbuilt: [(ActionID, String)] = [
            ("palette.restartSocketListener", "control-socket-restart"),
            ("palette.pro.upgrade", "account-billing"),
            ("help.featureFlags", "feature-flags"),
        ]
        for (id, feature) in unbuilt {
            registry.bindUnavailable([id], ActionFailure.needsAppCapability(feature))
        }
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
    /// empty `~/.config/ghostty/config` (R92).
    private static func openGhosttyConfig(_ context: AppActionContext) throws {
        let environment = ProcessInfo.processInfo.environment
        let base = environment["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".config")
        let url = GhosttyRuntime.editableConfigPath().map { URL(fileURLWithPath: $0) }
            ?? base.appending(path: "ghostty/config")
        try openCreatingIfMissing(url, contents: "", context)
    }

    private static func openCreatingIfMissing(_ url: URL, contents: String, _ context: AppActionContext) throws {
        let manager = FileManager.default
        if !manager.fileExists(atPath: url.path) {
            try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(contents.utf8).write(to: url, options: .withoutOverwriting)
        }
        try context.open(url)
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
        context.services.cache.browserTabs?.preference.defaultEngine = engine
        if engine == .chromium { context.services.chromiumWarmup.chromiumLikely(.defaultEngine) }
        guard let settings = context.services.settings else { return }
        Task {
            do { try await settings.setBrowserDefaultEngine(engine) } catch {
                logger.error("set browser.defaultEngine failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    static func documentationURL(topic: String?) -> URL {
        var url = URL(string: "https://cmux.com/docs")!
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_/"))
        if let topic = topic?.trimmingCharacters(in: CharacterSet(charactersIn: "/ ")), !topic.isEmpty,
           topic.unicodeScalars.allSatisfy(allowed.contains) {
            url.append(path: topic)
        }
        return url
    }
}
