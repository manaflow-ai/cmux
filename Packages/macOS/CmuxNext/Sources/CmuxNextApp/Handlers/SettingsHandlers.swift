import AppKit
import CmuxNextActions
import CmuxNextSettings
import os

/// Settings and help actions (category `settings`, except appearance, see
/// `AppearanceHandlers`). Settings live in cmux.json (architecture.md 1), so
/// "open settings" opens that file and toggles write it; the watcher applies
/// the change. Updates, CLI install, and account actions report that
/// cmux-next has no implementation yet.
enum SettingsHandlers {
    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "app.actions")

    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        registry.bind("palette.openCmuxSettingsFile", run: { _ in try openCmuxConfig(context) })
        registry.bind("palette.openGhosttySettings", run: { _ in try openGhosttyConfig(context) })
        registry.bind("reloadConfiguration", run: { _ in
            let settings = try requireSettings(context)
            Task { await settings.reload() }
        })
        registry.bind("palette.toggleSetting", run: { invocation in try toggleSetting(invocation, context) })
        registry.bind("sendFeedback", run: { _ in try context.open(URL(string: "https://github.com/manaflow-ai/cmux/issues/new")!) })
        registry.bind("help.documentation", run: { invocation in try context.open(documentationURL(topic: invocation["topic"]?.stringValue)) })

        let unbuilt: [(ActionID, String)] = [
            ("palette.checkForUpdates", "updates"),
            ("palette.applyUpdateIfAvailable", "updates"),
            ("palette.attemptUpdate", "updates"),
            ("palette.switchAppChannel", "updates"),
            ("palette.installCLI", "cli-install"),
            ("palette.uninstallCLI", "cli-install"),
            ("palette.makeDefaultTerminal", "default-terminal"),
            ("palette.shortcutKeymap", "shortcut-keymaps"),
            ("palette.restartSocketListener", "control-socket-restart"),
            ("palette.pro.upgrade", "account-billing"),
            ("palette.welcomeChecklist", "onboarding"),
            ("help.featureFlags", "feature-flags"),
        ]
        for (id, feature) in unbuilt {
            registry.bindUnavailable([id], ActionFailure.needsAppCapability(feature))
        }
    }

    static func requireSettings(_ context: AppActionContext) throws -> SettingsController {
        guard let settings = context.services.settings else { throw ActionFailure(message: "cmux.json is not loaded yet") }
        return settings
    }

    /// Opens cmux.json in the default editor, creating an empty one first.
    static func openCmuxConfig(_ context: AppActionContext) throws {
        let url = context.services.settings?.file.url ?? CmuxConfigFile.defaultURL()
        try openCreatingIfMissing(url, contents: "{\n}\n", context)
    }

    /// Opens Ghostty's config (terminal fonts, colors, keybinds), which cmux
    /// reads for every terminal.
    private static func openGhosttyConfig(_ context: AppActionContext) throws {
        let environment = ProcessInfo.processInfo.environment
        let base = environment["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".config")
        try openCreatingIfMissing(base.appending(path: "ghostty/config"), contents: "", context)
    }

    private static func openCreatingIfMissing(_ url: URL, contents: String, _ context: AppActionContext) throws {
        let manager = FileManager.default
        if !manager.fileExists(atPath: url.path) {
            try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(contents.utf8).write(to: url, options: .withoutOverwriting)
        }
        try context.open(url)
    }

    /// Writes a boolean setting at a dotted cmux.json path. Without `on`,
    /// flips the current value.
    private static func toggleSetting(_ invocation: ActionInvocation, _ context: AppActionContext) throws {
        let settings = try requireSettings(context)
        guard let setting = invocation["setting"]?.stringValue, !setting.isEmpty else {
            throw ActionFailure.invalidTarget("setting is required (a dotted cmux.json path)")
        }
        let path = CmuxConfigFile.keyPath(from: setting)
        let explicit = invocation["on"]?.boolValue
        Task {
            do {
                let current = try await settings.file.value(at: path)?.boolValue ?? false
                try await settings.set(.bool(explicit ?? !current), at: path)
            } catch {
                logger.error("toggle setting \(setting, privacy: .public) failed: \(String(describing: error), privacy: .public)")
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
