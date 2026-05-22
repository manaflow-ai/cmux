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

enum TerminalWarmPtyPoolSettings {
    static let enabledKey = "terminal.warmPtyPool"
    static let defaultEnabled = false
    static let didChangeNotification = Notification.Name("cmux.terminalWarmPtyPoolSettingsDidChange")

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: enabledKey) != nil else {
            return defaultEnabled
        }
        return defaults.bool(forKey: enabledKey)
    }

    static func setEnabled(
        _ enabled: Bool,
        defaults: UserDefaults = .standard,
        notificationCenter: NotificationCenter = .default
    ) {
        let wasEnabled = isEnabled(defaults: defaults)
        defaults.set(enabled, forKey: enabledKey)
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
        defaults.removeObject(forKey: enabledKey)
        let isNowEnabled = isEnabled(defaults: defaults)
        if wasEnabled != isNowEnabled {
            notifyDidChange(notificationCenter: notificationCenter)
        }
        return wasEnabled != isNowEnabled
    }

    static func notifyDidChange(notificationCenter: NotificationCenter = .default) {
        notificationCenter.post(name: didChangeNotification, object: nil)
    }
}

struct TerminalWarmPtyPoolStartupSignature: Equatable {
    struct FileFingerprint: Equatable {
        let path: String
        let exists: Bool
        let fileType: String
        let size: UInt64
        let modificationTime: TimeInterval
        let systemNumber: UInt64
        let systemFileNumber: UInt64
        let posixPermissions: UInt16
        let linkDestination: String?
    }

    let shellPath: String
    let shellName: String
    let environment: [String: String]
    let files: [FileFingerprint]

    static func current(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> TerminalWarmPtyPoolStartupSignature {
        let shellPath = resolvedShellPath(environment: environment)
        let shellName = resolvedShellName(shellPath: shellPath)
        let trackedEnvironment = trackedEnvironment(environment)
        let home = homeDirectory(environment: environment)
        let candidatePaths = startupCandidatePaths(
            shellName: shellName,
            environment: environment,
            home: home,
            fileManager: fileManager
        )
        let fingerprints = candidatePaths.flatMap {
            fileFingerprints(path: $0, fileManager: fileManager)
        }

        return TerminalWarmPtyPoolStartupSignature(
            shellPath: shellPath,
            shellName: shellName,
            environment: trackedEnvironment,
            files: fingerprints
        )
    }

    private static let trackedEnvironmentKeys = [
        "HOME",
        "USER",
        "LOGNAME",
        "SHELL",
        "ZDOTDIR",
        "ENV",
        "BASH_ENV",
        "XDG_CONFIG_HOME",
        "XONSHRC"
    ]

    private static func trackedEnvironment(_ environment: [String: String]) -> [String: String] {
        var result: [String: String] = [:]
        for key in trackedEnvironmentKeys {
            if let value = environment[key] {
                result[key] = value
            }
        }
        return result
    }

    private static func resolvedShellPath(environment: [String: String]) -> String {
        let rawShell = nonEmpty(environment["SHELL"]) ?? "/bin/zsh"
        return String(rawShell.split(whereSeparator: { $0 == " " || $0 == "\t" }).first ?? Substring(rawShell))
    }

    private static func resolvedShellName(shellPath: String) -> String {
        let name = URL(fileURLWithPath: shellPath).lastPathComponent
        return name.trimmingCharacters(in: CharacterSet(charactersIn: "-")).lowercased()
    }

    private static func homeDirectory(environment: [String: String]) -> String {
        nonEmpty(environment["HOME"]) ?? FileManager.default.homeDirectoryForCurrentUser.path
    }

    private static func xdgConfigHome(environment: [String: String], home: String) -> String {
        nonEmpty(environment["XDG_CONFIG_HOME"]) ?? (home as NSString).appendingPathComponent(".config")
    }

    private static func startupCandidatePaths(
        shellName: String,
        environment: [String: String],
        home: String,
        fileManager: FileManager
    ) -> [String] {
        var paths: [String] = []
        var seen = Set<String>()

        func append(_ path: String?) {
            guard let path = nonEmpty(path) else { return }
            appendPath(path, to: &paths, seen: &seen)
        }

        func appendHome(_ component: String) {
            append((home as NSString).appendingPathComponent(component))
        }

        func appendEnvironmentPath(_ key: String) {
            append(pathFromEnvironmentValue(environment[key], home: home))
        }

        func appendChildren(in directory: String, where matches: (String) -> Bool) {
            appendDirectoryChildren(
                in: directory,
                where: matches,
                to: &paths,
                seen: &seen,
                fileManager: fileManager
            )
        }

        let configHome = xdgConfigHome(environment: environment, home: home)
        switch shellName {
        case "zsh":
            for path in [
                "/etc/zshenv",
                "/etc/zprofile",
                "/etc/zshrc",
                "/etc/zlogin",
                "/etc/zlogout",
                "/etc/zsh/zshenv",
                "/etc/zsh/zprofile",
                "/etc/zsh/zshrc",
                "/etc/zsh/zlogin",
                "/etc/zsh/zlogout"
            ] {
                append(path)
            }
            let zdotdir = nonEmpty(environment["ZDOTDIR"]) ?? home
            for file in [".zshenv", ".zprofile", ".zshrc", ".zlogin", ".zlogout"] {
                append((zdotdir as NSString).appendingPathComponent(file))
            }

        case "bash":
            for path in ["/etc/profile", "/etc/bashrc", "/etc/bash.bashrc"] {
                append(path)
            }
            for file in [".bash_profile", ".bash_login", ".profile", ".bashrc", ".bash_logout"] {
                appendHome(file)
            }
            appendEnvironmentPath("BASH_ENV")

        case "fish":
            for directory in ["/etc/fish", "/opt/homebrew/etc/fish", "/usr/local/etc/fish"] {
                append((directory as NSString).appendingPathComponent("config.fish"))
                appendChildren(in: (directory as NSString).appendingPathComponent("conf.d")) {
                    $0.hasSuffix(".fish")
                }
            }
            let fishConfig = (configHome as NSString).appendingPathComponent("fish")
            append((fishConfig as NSString).appendingPathComponent("config.fish"))
            append((fishConfig as NSString).appendingPathComponent("fish_variables"))
            appendChildren(in: (fishConfig as NSString).appendingPathComponent("conf.d")) {
                $0.hasSuffix(".fish")
            }

        case "csh", "tcsh":
            for path in ["/etc/csh.cshrc", "/etc/csh.login", "/etc/csh.logout"] {
                append(path)
            }
            for file in [".cshrc", ".tcshrc", ".login", ".logout"] {
                appendHome(file)
            }

        case "ksh", "mksh", "pdksh":
            for path in ["/etc/profile", "/etc/ksh.kshrc"] {
                append(path)
            }
            for file in [".profile", ".kshrc"] {
                appendHome(file)
            }
            appendEnvironmentPath("ENV")

        case "sh", "dash", "ash":
            append("/etc/profile")
            appendHome(".profile")
            appendEnvironmentPath("ENV")

        case "elvish":
            append((configHome as NSString).appendingPathComponent("elvish/rc.elv"))
            appendHome(".elvish/rc.elv")

        case "nu", "nushell":
            let nushellConfig = (configHome as NSString).appendingPathComponent("nushell")
            for file in ["config.nu", "env.nu", "login.nu"] {
                append((nushellConfig as NSString).appendingPathComponent(file))
            }

        case "xonsh":
            if let xonshrc = nonEmpty(environment["XONSHRC"]) {
                for rawPath in xonshrc.split(separator: ":").map(String.init) {
                    append(pathFromEnvironmentValue(rawPath, home: home))
                }
            } else {
                appendHome(".xonshrc")
                append((configHome as NSString).appendingPathComponent("xonsh/rc.xsh"))
            }

        case "pwsh", "powershell":
            let powerShellConfig = (configHome as NSString).appendingPathComponent("powershell")
            append((powerShellConfig as NSString).appendingPathComponent("profile.ps1"))
            append((powerShellConfig as NSString).appendingPathComponent("Microsoft.PowerShell_profile.ps1"))
            appendChildren(in: powerShellConfig) {
                $0.hasSuffix(".ps1")
            }

        default:
            append("/etc/profile")
            appendHome(".profile")
            appendHome(".\(shellName)rc")
            appendHome(".\(shellName)_profile")
            append((configHome as NSString).appendingPathComponent("\(shellName)/config"))
            appendChildren(in: (configHome as NSString).appendingPathComponent(shellName)) {
                $0.hasPrefix("config.")
            }
            appendEnvironmentPath("ENV")
            appendEnvironmentPath("BASH_ENV")
        }

        return paths
    }

    private static func appendDirectoryChildren(
        in directory: String,
        where matches: (String) -> Bool,
        to paths: inout [String],
        seen: inout Set<String>,
        fileManager: FileManager
    ) {
        appendPath(directory, to: &paths, seen: &seen)
        guard let children = try? fileManager.contentsOfDirectory(atPath: directory) else { return }
        for child in children.sorted() where matches(child) {
            appendPath((directory as NSString).appendingPathComponent(child), to: &paths, seen: &seen)
        }
    }

    private static func appendPath(_ path: String, to paths: inout [String], seen: inout Set<String>) {
        let standardized = standardizedPath(path)
        guard seen.insert(standardized).inserted else { return }
        paths.append(standardized)
    }

    private static func fileFingerprints(path: String, fileManager: FileManager) -> [FileFingerprint] {
        let standardized = standardizedPath(path)
        let primary = fileFingerprint(path: standardized, fileManager: fileManager)
        let resolved = (standardized as NSString).resolvingSymlinksInPath
        guard resolved != standardized else { return [primary] }
        return [primary, fileFingerprint(path: resolved, fileManager: fileManager)]
    }

    private static func fileFingerprint(path: String, fileManager: FileManager) -> FileFingerprint {
        guard let attributes = try? fileManager.attributesOfItem(atPath: path) else {
            return FileFingerprint(
                path: path,
                exists: false,
                fileType: "",
                size: 0,
                modificationTime: 0,
                systemNumber: 0,
                systemFileNumber: 0,
                posixPermissions: 0,
                linkDestination: nil
            )
        }

        return FileFingerprint(
            path: path,
            exists: true,
            fileType: (attributes[.type] as? FileAttributeType)?.rawValue ?? "",
            size: (attributes[.size] as? NSNumber)?.uint64Value ?? 0,
            modificationTime: (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0,
            systemNumber: (attributes[.systemNumber] as? NSNumber)?.uint64Value ?? 0,
            systemFileNumber: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0,
            posixPermissions: (attributes[.posixPermissions] as? NSNumber)?.uint16Value ?? 0,
            linkDestination: try? fileManager.destinationOfSymbolicLink(atPath: path)
        )
    }

    private static func pathFromEnvironmentValue(_ value: String?, home: String) -> String? {
        guard var path = nonEmpty(value) else { return nil }
        if path.hasPrefix("~/") {
            path = (home as NSString).appendingPathComponent(String(path.dropFirst(2)))
        } else if path == "~" {
            path = home
        } else if path.hasPrefix("$HOME/") {
            path = (home as NSString).appendingPathComponent(String(path.dropFirst(6)))
        } else if path.hasPrefix("${HOME}/") {
            path = (home as NSString).appendingPathComponent(String(path.dropFirst(8)))
        }
        return path
    }

    private static func standardizedPath(_ path: String) -> String {
        ((path as NSString).expandingTildeInPath as NSString).standardizingPath
    }

    private static func nonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
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
