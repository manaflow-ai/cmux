import Darwin
import Foundation

enum WorkspaceTitlebarSettings {
    static let showTitlebarKey = "workspaceTitlebarVisible"
    static let defaultShowTitlebar = true

    static func isVisible(defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: showTitlebarKey) == nil {
            return defaultShowTitlebar
        }
        return defaults.bool(forKey: showTitlebarKey)
    }
}
enum WorkspacePresentationModeSettings {
    static let modeKey = "workspacePresentationMode"

    enum Mode: String {
        case standard
        case minimal
    }

    static let defaultMode: Mode = .standard

    static func mode(for rawValue: String?) -> Mode {
        Mode(rawValue: rawValue ?? "") ?? defaultMode
    }

    static func mode(defaults: UserDefaults = .standard) -> Mode {
        mode(for: defaults.string(forKey: modeKey))
    }

    static func isMinimal(defaults: UserDefaults = .standard) -> Bool {
        mode(defaults: defaults) == .minimal
    }
}

enum WorkspaceButtonFadeSettings {
    static let modeKey = "workspaceButtonsFadeMode"
    static let legacyTitlebarControlsVisibilityModeKey = "titlebarControlsVisibilityMode"
    static let legacyPaneTabBarControlsVisibilityModeKey = "paneTabBarControlsVisibilityMode"

    enum Mode: String {
        case enabled
        case disabled
    }

    static let defaultMode: Mode = .disabled

    static func mode(for rawValue: String?) -> Mode {
        Mode(rawValue: rawValue ?? "") ?? defaultMode
    }

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        mode(for: defaults.string(forKey: modeKey)) == .enabled
    }

    static func initializeStoredModeIfNeeded(defaults: UserDefaults = .standard) {
        guard defaults.string(forKey: modeKey) == nil else { return }

        if let migratedMode = migratedLegacyMode(defaults: defaults) {
            defaults.set(migratedMode.rawValue, forKey: modeKey)
            return
        }

        let initialMode: Mode = WorkspaceTitlebarSettings.isVisible(defaults: defaults) ? .disabled : .enabled
        defaults.set(initialMode.rawValue, forKey: modeKey)
    }

    private static func migratedLegacyMode(defaults: UserDefaults) -> Mode? {
        let legacyValues = [
            defaults.string(forKey: legacyTitlebarControlsVisibilityModeKey),
            defaults.string(forKey: legacyPaneTabBarControlsVisibilityModeKey),
        ]

        if legacyValues.contains(where: { $0 == "onHover" || $0 == "hover" || $0 == "enabled" }) {
            return .enabled
        }
        if legacyValues.contains(where: { $0 == "always" || $0 == "disabled" }) {
            return .disabled
        }
        return nil
    }
}

enum PaneFirstClickFocusSettings {
    static let enabledKey = "paneFirstClickFocus.enabled"
    static let defaultEnabled = false

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: enabledKey) as? Bool ?? defaultEnabled
    }
}

enum TerminalScrollBarSettings {
    static let showScrollBarKey = "terminal.showScrollBar"
    static let defaultShowScrollBar = true
    static let didChangeNotification = Notification.Name("cmux.terminalScrollBarSettingsDidChange")

    static func isVisible(defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: showScrollBarKey) == nil {
            return defaultShowScrollBar
        }
        return defaults.bool(forKey: showScrollBarKey)
    }

    static func notifyDidChange(notificationCenter: NotificationCenter = .default) {
        notificationCenter.post(name: didChangeNotification, object: nil)
    }
}

enum TerminalTextBoxInputSettings {
    static let maxLinesKey = "terminal.textBoxMaxLines"
    static let defaultMaxLines = 10
    static let minimumMaxLines = 1
    static let maximumMaxLines = 20

    static func resolvedMaxLines(_ value: Int) -> Int {
        min(max(value, minimumMaxLines), maximumMaxLines)
    }

    static func maxLines(defaults: UserDefaults = .standard) -> Int {
        guard let value = defaults.object(forKey: maxLinesKey) as? Int else {
            return defaultMaxLines
        }
        return resolvedMaxLines(value)
    }
}

enum TerminalCopyOnSelectSettings {
    static let copyOnSelectKey = "terminal.copyOnSelect"
    static let defaultCopyOnSelect = false
    static let didChangeNotification = Notification.Name("cmux.terminalCopyOnSelectSettingsDidChange")

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        storedValue(defaults: defaults) ?? defaultCopyOnSelect
    }

    static func storedValue(defaults: UserDefaults = .standard) -> Bool? {
        defaults.object(forKey: copyOnSelectKey) as? Bool
    }

    static func ghosttyCopyOnSelectValue(defaults: UserDefaults = .standard) -> String? {
        guard let enabled = storedValue(defaults: defaults) else { return nil }
        return enabled ? "clipboard" : "false"
    }

    static func ghosttyConfigContents(defaults: UserDefaults = .standard) -> String? {
        guard let value = ghosttyCopyOnSelectValue(defaults: defaults) else { return nil }
        return "copy-on-select = \(value)"
    }

    static func setEnabled(
        _ enabled: Bool,
        defaults: UserDefaults = .standard,
        notificationCenter: NotificationCenter = .default
    ) {
        let wasEnabled = isEnabled(defaults: defaults)
        defaults.set(enabled, forKey: copyOnSelectKey)
        if wasEnabled != enabled {
            notifyDidChange(notificationCenter: notificationCenter)
        }
    }

    @discardableResult
    static func reset(
        defaults: UserDefaults = .standard,
        notificationCenter: NotificationCenter = .default
    ) -> Bool {
        let wasEnabled = isEnabled(defaults: defaults)
        defaults.removeObject(forKey: copyOnSelectKey)
        let didChange = wasEnabled != isEnabled(defaults: defaults)
        if didChange {
            notifyDidChange(notificationCenter: notificationCenter)
        }
        return didChange
    }

    static func notifyDidChange(notificationCenter: NotificationCenter = .default) {
        notificationCenter.post(name: didChangeNotification, object: nil)
    }
}

enum TerminalManagedGhosttySettings {
    static func ghosttyConfigContents(defaults: UserDefaults = .standard) -> String? {
        let lines = [
            TerminalCopyOnSelectSettings.ghosttyConfigContents(defaults: defaults),
        ].compactMap { $0 }
        guard !lines.isEmpty else { return nil }
        return lines.joined(separator: "\n")
    }
}

enum AgentSessionAutoResumeSettings {
    static let autoResumeAgentSessionsKey = "terminal.autoResumeAgentSessions"
    static let defaultAutoResumeAgentSessions = true
    static let didChangeNotification = Notification.Name("cmux.agentSessionAutoResumeSettingsDidChange")

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: autoResumeAgentSessionsKey) != nil else {
            return defaultAutoResumeAgentSessions
        }
        return defaults.bool(forKey: autoResumeAgentSessionsKey)
    }

    static func setEnabled(
        _ enabled: Bool,
        defaults: UserDefaults = .standard,
        notificationCenter: NotificationCenter = .default
    ) {
        let wasEnabled = isEnabled(defaults: defaults)
        defaults.set(enabled, forKey: autoResumeAgentSessionsKey)
        if wasEnabled != enabled {
            notifyDidChange(notificationCenter: notificationCenter)
        }
    }

    @discardableResult
    static func reset(
        defaults: UserDefaults = .standard,
        notificationCenter: NotificationCenter = .default
    ) -> Bool {
        let wasEnabled = isEnabled(defaults: defaults)
        defaults.removeObject(forKey: autoResumeAgentSessionsKey)
        let didChange = wasEnabled != isEnabled(defaults: defaults)
        if didChange {
            notifyDidChange(notificationCenter: notificationCenter)
        }
        return didChange
    }

    static func notifyDidChange(notificationCenter: NotificationCenter = .default) {
        notificationCenter.post(name: didChangeNotification, object: nil)
    }
}

enum AgentHibernationSettings {
    struct Values: Equatable, Sendable {
        var enabled: Bool
        var idleSeconds: TimeInterval
        var maxLiveTerminals: Int
        var confirmationSeconds: TimeInterval
    }

    static let enabledKey = "terminal.agentHibernation.enabled"
    static let idleSecondsKey = "terminal.agentHibernation.idleSeconds"
    static let maxLiveTerminalsKey = "terminal.agentHibernation.maxLiveTerminals"
    static let confirmationSecondsKey = "terminal.agentHibernation.confirmationSeconds"

    static let defaultEnabled = false
    static let defaultIdleSeconds: TimeInterval = 60 * 60
    static let defaultMaxLiveTerminals = 12
    static let defaultConfirmationSeconds: TimeInterval = 60
    static let didChangeNotification = Notification.Name("cmux.agentHibernationSettingsDidChange")

    static func values(defaults: UserDefaults = .standard) -> Values {
        Values(
            enabled: isEnabled(defaults: defaults),
            idleSeconds: idleSeconds(defaults: defaults),
            maxLiveTerminals: maxLiveTerminals(defaults: defaults),
            confirmationSeconds: confirmationSeconds(defaults: defaults)
        )
    }

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: enabledKey) != nil else { return defaultEnabled }
        return defaults.bool(forKey: enabledKey)
    }

    static func idleSeconds(defaults: UserDefaults = .standard) -> TimeInterval {
        guard defaults.object(forKey: idleSecondsKey) != nil else { return defaultIdleSeconds }
        return sanitizedIdleSeconds(defaults.double(forKey: idleSecondsKey))
    }

    static func maxLiveTerminals(defaults: UserDefaults = .standard) -> Int {
        guard defaults.object(forKey: maxLiveTerminalsKey) != nil else { return defaultMaxLiveTerminals }
        return sanitizedMaxLiveTerminals(defaults.integer(forKey: maxLiveTerminalsKey))
    }

    static func confirmationSeconds(defaults: UserDefaults = .standard) -> TimeInterval {
        guard defaults.object(forKey: confirmationSecondsKey) != nil else { return defaultConfirmationSeconds }
        return sanitizedConfirmationSeconds(defaults.double(forKey: confirmationSecondsKey))
    }

    static func sanitizedIdleSeconds(_ value: TimeInterval) -> TimeInterval {
        guard value.isFinite else { return defaultIdleSeconds }
        return min(max(value.rounded(), 5), 7 * 24 * 60 * 60)
    }

    static func sanitizedMaxLiveTerminals(_ value: Int) -> Int {
        min(max(value, 1), 256)
    }

    static func sanitizedConfirmationSeconds(_ value: TimeInterval) -> TimeInterval {
        guard value.isFinite else { return defaultConfirmationSeconds }
        return min(max(value.rounded(), 5), 60 * 60)
    }

    static func setValues(
        enabled: Bool? = nil,
        idleSeconds: TimeInterval? = nil,
        maxLiveTerminals: Int? = nil,
        defaults: UserDefaults = .standard,
        notificationCenter: NotificationCenter = .default
    ) {
        let oldValues = values(defaults: defaults)
        if let enabled {
            defaults.set(enabled, forKey: enabledKey)
        }
        if let idleSeconds {
            defaults.set(sanitizedIdleSeconds(idleSeconds), forKey: idleSecondsKey)
        }
        if let maxLiveTerminals {
            defaults.set(sanitizedMaxLiveTerminals(maxLiveTerminals), forKey: maxLiveTerminalsKey)
        }
        if oldValues != values(defaults: defaults) {
            notifyDidChange(notificationCenter: notificationCenter)
        }
    }

    @discardableResult
    static func reset(
        defaults: UserDefaults = .standard,
        notificationCenter: NotificationCenter = .default
    ) -> Bool {
        let oldValues = values(defaults: defaults)
        defaults.removeObject(forKey: enabledKey)
        defaults.removeObject(forKey: idleSecondsKey)
        defaults.removeObject(forKey: maxLiveTerminalsKey)
        defaults.removeObject(forKey: confirmationSecondsKey)
        let didChange = oldValues != values(defaults: defaults)
        if didChange {
            notifyDidChange(notificationCenter: notificationCenter)
        }
        return didChange
    }

    static func notifyDidChange(notificationCenter: NotificationCenter = .default) {
        notificationCenter.post(name: didChangeNotification, object: nil)
    }
}

enum AgentHibernationHookPrerequisites {
    struct HookProbe: Sendable {
        let configDir: String
        let configFile: String
        let envOverride: String?
        let envOverrideSubpath: String?
        let markers: [String]
    }

    typealias FileExists = (String) -> Bool
    typealias ReadFile = (String) -> String?

    private static let probes: [HookProbe] = [
        HookProbe(
            configDir: ".codex",
            configFile: "hooks.json",
            envOverride: "CODEX_HOME",
            envOverrideSubpath: nil,
            markers: ["hooks codex", "codex-hook"]
        ),
        HookProbe(
            configDir: ".grok/hooks",
            configFile: "cmux-session.json",
            envOverride: "GROK_HOME",
            envOverrideSubpath: "hooks",
            markers: ["cmux-grok-hook-v2", "hooks grok"]
        ),
        HookProbe(
            configDir: ".config/opencode",
            configFile: "plugins/cmux-session.js",
            envOverride: "OPENCODE_CONFIG_DIR",
            envOverrideSubpath: nil,
            markers: ["cmux-opencode-session-plugin-marker"]
        ),
        HookProbe(
            configDir: ".pi/agent",
            configFile: "extensions/cmux-session.ts",
            envOverride: "PI_CODING_AGENT_DIR",
            envOverrideSubpath: nil,
            markers: ["cmux-pi-session-extension-marker"]
        ),
        HookProbe(
            configDir: ".config/amp",
            configFile: "plugins/cmux-session.ts",
            envOverride: nil,
            envOverrideSubpath: nil,
            markers: ["cmux-amp-session-extension-marker"]
        ),
        HookProbe(
            configDir: ".cursor",
            configFile: "hooks.json",
            envOverride: nil,
            envOverrideSubpath: nil,
            markers: ["hooks cursor"]
        ),
        HookProbe(
            configDir: ".gemini",
            configFile: "settings.json",
            envOverride: nil,
            envOverrideSubpath: nil,
            markers: ["hooks gemini"]
        ),
        HookProbe(
            configDir: ".gemini/config",
            configFile: "hooks.json",
            envOverride: nil,
            envOverrideSubpath: nil,
            markers: ["cmux-antigravity-hook-v2", "hooks antigravity"]
        ),
        HookProbe(
            configDir: ".rovodev",
            configFile: "config.yml",
            envOverride: nil,
            envOverrideSubpath: nil,
            markers: ["hooks rovodev"]
        ),
        HookProbe(
            configDir: ".hermes",
            configFile: "config.yaml",
            envOverride: "HERMES_HOME",
            envOverrideSubpath: nil,
            markers: ["hooks hermes-agent", "cmux hooks hermes-agent begin"]
        ),
        HookProbe(
            configDir: ".copilot",
            configFile: "config.json",
            envOverride: "COPILOT_HOME",
            envOverrideSubpath: nil,
            markers: ["hooks copilot"]
        ),
        HookProbe(
            configDir: ".codebuddy",
            configFile: "settings.json",
            envOverride: "CODEBUDDY_CONFIG_DIR",
            envOverrideSubpath: nil,
            markers: ["hooks codebuddy"]
        ),
        HookProbe(
            configDir: ".factory",
            configFile: "settings.json",
            envOverride: nil,
            envOverrideSubpath: nil,
            markers: ["hooks factory"]
        ),
        HookProbe(
            configDir: ".qoder",
            configFile: "settings.json",
            envOverride: "QODER_CONFIG_DIR",
            envOverrideSubpath: nil,
            markers: ["hooks qoder"]
        ),
    ]

    static func hasAnyInstalledAgentHook(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileExists: FileExists = { FileManager.default.fileExists(atPath: $0) },
        readFile: ReadFile = { try? String(contentsOfFile: $0, encoding: .utf8) }
    ) -> Bool {
        probes.contains { probe in
            let path = hookConfigPath(for: probe, environment: environment)
            guard fileExists(path), let contents = readFile(path) else { return false }
            return probe.markers.contains { contents.contains($0) }
        }
    }

    static func missingHooksWarning(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        trustedResumeBindingExists: Bool = false,
        builtInClaudeWrapperEnabled: Bool = false,
        fileExists: FileExists = { FileManager.default.fileExists(atPath: $0) },
        readFile: ReadFile = { try? String(contentsOfFile: $0, encoding: .utf8) }
    ) -> String? {
        guard !trustedResumeBindingExists else { return nil }
        guard !hasAnyInstalledAgentHook(
            environment: environment,
            fileExists: fileExists,
            readFile: readFile
        ) else { return nil }

        return missingHooksWarningMessage(builtInClaudeWrapperEnabled: builtInClaudeWrapperEnabled)
    }

    static func missingHooksWarningMessage(builtInClaudeWrapperEnabled: Bool = false) -> String {
        if builtInClaudeWrapperEnabled {
            return String(
                localized: "settings.terminal.agentHibernation.warning.missingHooksWithClaudeWrapper",
                defaultValue: "cmux could not find installed agent hooks for this app session. The built-in Claude Code wrapper can still report Claude sessions, but other agents need captured session hooks or trusted resume bindings. Run `cmux hooks setup`, or restart cmux from a shell that exports any agent-specific config directory overrides."
            )
        }
        return String(
            localized: "settings.terminal.agentHibernation.warning.missingHooks",
            defaultValue: "cmux could not find installed agent hooks for this app session. Agent Hibernation only affects agents with captured session hooks or trusted resume bindings. Run `cmux hooks setup`, or restart cmux from a shell that exports any agent-specific config directory overrides."
        )
    }

    static func enablementResponse(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        trustedResumeBindingExists: Bool = false,
        builtInClaudeWrapperEnabled: Bool = false,
        fileExists: FileExists = { FileManager.default.fileExists(atPath: $0) },
        readFile: ReadFile = { try? String(contentsOfFile: $0, encoding: .utf8) }
    ) -> String {
        guard let warning = missingHooksWarning(
            environment: environment,
            trustedResumeBindingExists: trustedResumeBindingExists,
            builtInClaudeWrapperEnabled: builtInClaudeWrapperEnabled,
            fileExists: fileExists,
            readFile: readFile
        ) else { return "OK" }

        return "OK\nWARNING: \(warning)"
    }

    private static func hookConfigPath(
        for probe: HookProbe,
        environment: [String: String]
    ) -> String {
        let configDir: URL
        if let envOverride = probe.envOverride,
           let rawValue = normalizedEnvironmentValue(environment[envOverride]) {
            var url = URL(
                fileURLWithPath: NSString(string: rawValue).expandingTildeInPath,
                isDirectory: true
            )
            if let subpath = probe.envOverrideSubpath,
               !subpath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                url.appendPathComponent(subpath, isDirectory: true)
            }
            configDir = url
        } else {
            let home = normalizedEnvironmentValue(environment["HOME"]) ?? NSHomeDirectory()
            configDir = URL(fileURLWithPath: home, isDirectory: true)
                .appendingPathComponent(probe.configDir, isDirectory: true)
        }

        return configDir
            .appendingPathComponent(probe.configFile, isDirectory: false)
            .path
    }

    private static func normalizedEnvironmentValue(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}

enum AgentHibernationTrackingGate {
    private static let lock = NSLock()
    private static var enabled = AgentHibernationSettings.isEnabled()

    static func isEnabled() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return enabled
    }

    static func setEnabled(_ nextEnabled: Bool) {
        lock.lock()
        enabled = nextEnabled
        lock.unlock()
    }
}

enum RightSidebarBetaFeatureSettings {
    static let dockEnabledKey = "rightSidebar.beta.dock.enabled"

    static let defaultDockEnabled = false

    nonisolated static func isDockEnabled(defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: dockEnabledKey) != nil else { return defaultDockEnabled }
        return defaults.bool(forKey: dockEnabledKey)
    }
}

enum UITestLaunchManifest {
    static let argumentName = "-cmuxUITestLaunchManifest"

    struct Payload: Decodable {
        let environment: [String: String]
    }

    static func applyIfPresent(
        arguments: [String] = CommandLine.arguments,
        loadData: (String) -> Data? = { path in
            try? Data(contentsOf: URL(fileURLWithPath: path))
        },
        applyEnvironment: (String, String) -> Void = { key, value in
            setenv(key, value, 1)
        }
    ) {
        guard let path = manifestPath(from: arguments),
              let data = loadData(path),
              let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            return
        }

        for (key, value) in payload.environment {
            applyEnvironment(key, value)
        }
    }

    static func manifestPath(from arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: argumentName) else { return nil }
        let valueIndex = arguments.index(after: index)
        guard valueIndex < arguments.endIndex else { return nil }

        let rawPath = arguments[valueIndex].trimmingCharacters(in: .whitespacesAndNewlines)
        return rawPath.isEmpty ? nil : rawPath
    }
}
