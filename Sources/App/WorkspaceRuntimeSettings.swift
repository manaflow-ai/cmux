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

enum TerminalSessionBackend: String, Codable, Sendable, CaseIterable, Identifiable {
    case native
    case zellij

    var id: String { rawValue }
}

struct TerminalSessionIdentity: Codable, Sendable, Equatable {
    var backend: TerminalSessionBackend
    var name: String

    init(backend: TerminalSessionBackend, name: String) {
        self.backend = backend
        self.name = name
    }
}

enum TerminalSessionBackendSettings {
    static let backendKey = "terminal.sessionBackend"
    static let defaultBackend: TerminalSessionBackend = .native

    static func backend(for rawValue: String?) -> TerminalSessionBackend {
        TerminalSessionBackend(rawValue: rawValue ?? "") ?? defaultBackend
    }

    static func backend(defaults: UserDefaults = .standard) -> TerminalSessionBackend {
        backend(for: defaults.string(forKey: backendKey))
    }

    static func setBackend(_ backend: TerminalSessionBackend, defaults: UserDefaults = .standard) {
        defaults.set(backend.rawValue, forKey: backendKey)
    }

    @discardableResult
    static func reset(defaults: UserDefaults = .standard) -> Bool {
        let previous = backend(defaults: defaults)
        defaults.removeObject(forKey: backendKey)
        return previous != backend(defaults: defaults)
    }

    static func defaultSessionName(workspaceId: UUID, surfaceId: UUID) -> String {
        "cmux-\(workspaceId.uuidString.lowercased())-\(surfaceId.uuidString.lowercased())"
    }

    static func resolvedIdentity(
        explicit identity: TerminalSessionIdentity?,
        defaultName: String,
        hasExplicitStartup: Bool,
        defaults: UserDefaults = .standard,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> TerminalSessionIdentity? {
        if let identity {
            return normalizedIdentity(identity)
        }

        guard environment["ZELLIJ"]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false else {
            return nil
        }

        guard backend(defaults: defaults) == .zellij else { return nil }
        guard !hasExplicitStartup else { return nil }
        return TerminalSessionIdentity(backend: .zellij, name: defaultName)
    }

    static func zellijAttachCommand(identity: TerminalSessionIdentity, workingDirectory: String?) -> String? {
        guard identity.backend == .zellij else { return nil }
        let sessionName = identity.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sessionName.isEmpty else { return nil }

        var args = [
            "zellij",
            "attach",
            "--create",
            "--force-run-commands",
            sessionName,
            "options",
            "--on-force-close",
            "detach",
            "--session-serialization",
            "true",
            "--pane-viewport-serialization",
            "true",
            "--scrollback-lines-to-serialize",
            "0",
            "--serialization-interval",
            "60",
            "--support-kitty-keyboard-protocol",
            "true",
        ]

        if let workingDirectory = normalizedString(workingDirectory) {
            args.append(contentsOf: ["--default-cwd", workingDirectory])
        }

        return "exec " + args.map(shellSingleQuoted).joined(separator: " ")
    }

    static func sanitizeInheritedConfig(
        _ config: inout CmuxSurfaceConfigTemplate,
        sourceIdentity: TerminalSessionIdentity?
    ) {
        guard sourceIdentity?.backend == .zellij else { return }
        config.command = nil
        config.initialInput = nil
        config.waitAfterCommand = false
    }

    private static func normalizedIdentity(_ identity: TerminalSessionIdentity) -> TerminalSessionIdentity? {
        guard identity.backend != .native else { return nil }
        guard let name = normalizedString(identity.name) else { return nil }
        return TerminalSessionIdentity(backend: identity.backend, name: name)
    }

    private static func normalizedString(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private static func shellSingleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
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
