import Darwin
import CMUXCmxProtocol
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

enum DesktopCmxBackendSettings {
    static let enabledKey = "desktopCmxBackend.enabled"
    static let environmentKey = "CMUX_DESKTOP_CMX_BACKEND"
    static let disableEnvironmentKey = "CMUX_DESKTOP_CMX_BACKEND_DISABLED"
    static let executableEnvironmentKey = "CMUX_DESKTOP_CMX_EXECUTABLE"
    static let remoteDaemonManifestInfoKey = "CMUXRemoteDaemonManifestJSON"
    static let remoteDaemonManifestEnvironmentKey = "CMUX_REMOTE_DAEMON_MANIFEST_JSON"
    static let remoteDaemonAppVersionEnvironmentKey = "CMUX_REMOTE_DAEMON_APP_VERSION"
    static let remoteDaemonBuildEnvironmentKey = "CMUX_REMOTE_DAEMON_BUILD"
    static let remoteDaemonCommitEnvironmentKey = "CMUX_REMOTE_DAEMON_COMMIT"

    static func isEnabled(
        defaults: UserDefaults = .standard,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        if truthy(environment[disableEnvironmentKey]) {
            return false
        }
        if let environmentValue = boolValue(environment[environmentKey]) {
            return environmentValue
        }
        if let tagKey = tagScopedEnabledKey(environment: environment),
           let tagValue = defaults.object(forKey: tagKey) as? Bool {
            return tagValue
        }
        if let defaultValue = defaults.object(forKey: enabledKey) as? Bool {
            return defaultValue
        }
        return false
    }

    static func tagScopedEnabledKey(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        guard let rawTag = launchTag(environment: environment) else {
            return nil
        }
        let safeTag = rawTag.map { character -> Character in
            character.isLetter || character.isNumber || character == "-" || character == "_" ? character : "-"
        }.map(String.init).joined()
        return "\(enabledKey).\(safeTag)"
    }

    static func runtimePaths(environment: [String: String] = ProcessInfo.processInfo.environment) -> CmxDesktopRuntimePaths {
        CmxDesktopRuntimePathResolver.resolve(tag: launchTag(environment: environment))
    }

    static func launchTag(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) -> String? {
        if let rawTag = environment["CMUX_TAG"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !rawTag.isEmpty {
            return rawTag
        }

        guard let bundleIdentifier = bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
              bundleIdentifier.hasPrefix("\(SocketControlSettings.baseDebugBundleIdentifier).") else {
            return nil
        }
        let suffix = bundleIdentifier.dropFirst(SocketControlSettings.baseDebugBundleIdentifier.count + 1)
        let tag = suffix
            .replacingOccurrences(of: ".", with: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return tag.isEmpty ? nil : tag
    }

    static func executableURL(
        bundle: Bundle = .main,
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        if let rawPath = environment[executableEnvironmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !rawPath.isEmpty {
            return URL(fileURLWithPath: rawPath)
        }
        guard let bundledURL = bundle.resourceURL?.appendingPathComponent("bin/cmx"),
              fileManager.isExecutableFile(atPath: bundledURL.path) else {
            return nil
        }
        return bundledURL
    }

    static func applyRemoteDaemonMetadata(
        to environment: inout [String: String],
        bundle: Bundle = .main
    ) {
        let info = bundle.infoDictionary ?? [:]
        setEnvironmentValueIfMissing(
            &environment,
            key: remoteDaemonManifestEnvironmentKey,
            value: info[remoteDaemonManifestInfoKey] as? String
        )
        setEnvironmentValueIfMissing(
            &environment,
            key: remoteDaemonAppVersionEnvironmentKey,
            value: info["CFBundleShortVersionString"] as? String
        )
        setEnvironmentValueIfMissing(
            &environment,
            key: remoteDaemonBuildEnvironmentKey,
            value: info["CFBundleVersion"] as? String
        )
        setEnvironmentValueIfMissing(
            &environment,
            key: remoteDaemonCommitEnvironmentKey,
            value: info["CMUXCommit"] as? String
        )
    }

    private static func truthy(_ rawValue: String?) -> Bool {
        boolValue(rawValue) == true
    }

    private static func setEnvironmentValueIfMissing(
        _ environment: inout [String: String],
        key: String,
        value: String?
    ) {
        if environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            return
        }
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return
        }
        environment[key] = trimmed
    }

    private static func boolValue(_ rawValue: String?) -> Bool? {
        guard let normalized = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !normalized.isEmpty else {
            return nil
        }
        switch normalized {
        case "1", "true", "yes", "on", "enabled":
            return true
        case "0", "false", "no", "off", "disabled":
            return false
        default:
            return nil
        }
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
