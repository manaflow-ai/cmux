import AppKit
import Darwin
import Foundation

struct AgentHookIntegration: Identifiable, Hashable, Sendable {
    let name: String
    let displayName: String
    let commandNames: [String]
    let configDir: String?
    let configFile: String?
    let configDirEnvOverride: String?
    let hookMarkers: [String]
    let currentMarkers: [String]
    let isClaudeWrapper: Bool

    var id: String { name }

    var installCommand: String {
        if isClaudeWrapper {
            return "cmux settings open --section automation"
        }
        return "cmux hooks \(name) install"
    }
}

enum AgentHookIntegrationStatus: Equatable, Sendable {
    case enabled
    case disabled
    case installed(path: String)
    case updateAvailable(path: String)
    case notInstalled(path: String?)
    case unreadable(path: String)
    case unknown

    var isActive: Bool {
        switch self {
        case .enabled, .installed:
            return true
        case .disabled, .updateAvailable, .notInstalled, .unreadable, .unknown:
            return false
        }
    }

    var isUpdateAvailable: Bool {
        if case .updateAvailable = self {
            return true
        }
        return false
    }
}

struct AgentHookInstallResult: Sendable {
    let succeeded: Bool
    let message: String
}

struct AgentHookDiffResult: Sendable {
    let succeeded: Bool
    let message: String
    let diff: String
}

enum AgentHookIntegrationSettings {
    static let promptEnabledKey = "agentHookSetupPromptEnabled"
    static let defaultPromptEnabled = true
    static let statusDidChangeNotification = Notification.Name("cmux.agentHookIntegration.statusDidChange")

    private static let promptCooldown: TimeInterval = 24 * 60 * 60
    private static let configFileWatcher = ConfigFileWatcher()

    static let allAgents: [AgentHookIntegration] = [
        AgentHookIntegration(
            name: "claude",
            displayName: "Claude Code",
            commandNames: ["claude"],
            configDir: nil,
            configFile: nil,
            configDirEnvOverride: nil,
            hookMarkers: [],
            currentMarkers: [],
            isClaudeWrapper: true
        ),
        AgentHookIntegration(
            name: "codex",
            displayName: "Codex",
            commandNames: ["codex"],
            configDir: ".codex",
            configFile: "hooks.json",
            configDirEnvOverride: "CODEX_HOME",
            hookMarkers: ["cmux hooks codex", "cmux codex-hook"],
            currentMarkers: ["CMUX_AGENT_HOOK_VERSION=1"],
            isClaudeWrapper: false
        ),
        AgentHookIntegration(
            name: "opencode",
            displayName: "OpenCode",
            commandNames: ["opencode", "open-code"],
            configDir: ".config/opencode",
            configFile: "plugins/cmux-session.js",
            configDirEnvOverride: "OPENCODE_CONFIG_DIR",
            hookMarkers: ["cmux-opencode-session-plugin-marker", "cmux hooks opencode"],
            currentMarkers: ["cmux-opencode-session-plugin-marker v1"],
            isClaudeWrapper: false
        ),
        AgentHookIntegration(
            name: "cursor",
            displayName: "Cursor",
            commandNames: ["cursor"],
            configDir: ".cursor",
            configFile: "hooks.json",
            configDirEnvOverride: nil,
            hookMarkers: ["cmux hooks cursor"],
            currentMarkers: ["CMUX_AGENT_HOOK_VERSION=1"],
            isClaudeWrapper: false
        ),
        AgentHookIntegration(
            name: "gemini",
            displayName: "Gemini",
            commandNames: ["gemini"],
            configDir: ".gemini",
            configFile: "settings.json",
            configDirEnvOverride: nil,
            hookMarkers: ["cmux hooks gemini"],
            currentMarkers: ["CMUX_AGENT_HOOK_VERSION=1"],
            isClaudeWrapper: false
        ),
        AgentHookIntegration(
            name: "copilot",
            displayName: "Copilot",
            commandNames: ["copilot"],
            configDir: ".copilot",
            configFile: "config.json",
            configDirEnvOverride: nil,
            hookMarkers: ["cmux hooks copilot"],
            currentMarkers: ["CMUX_AGENT_HOOK_VERSION=1"],
            isClaudeWrapper: false
        ),
        AgentHookIntegration(
            name: "codebuddy",
            displayName: "CodeBuddy",
            commandNames: ["codebuddy"],
            configDir: ".codebuddy",
            configFile: "settings.json",
            configDirEnvOverride: nil,
            hookMarkers: ["cmux hooks codebuddy"],
            currentMarkers: ["CMUX_AGENT_HOOK_VERSION=1"],
            isClaudeWrapper: false
        ),
        AgentHookIntegration(
            name: "factory",
            displayName: "Factory",
            commandNames: ["factory"],
            configDir: ".factory",
            configFile: "settings.json",
            configDirEnvOverride: nil,
            hookMarkers: ["cmux hooks factory"],
            currentMarkers: ["CMUX_AGENT_HOOK_VERSION=1"],
            isClaudeWrapper: false
        ),
        AgentHookIntegration(
            name: "qoder",
            displayName: "Qoder",
            commandNames: ["qoder"],
            configDir: ".qoder",
            configFile: "settings.json",
            configDirEnvOverride: nil,
            hookMarkers: ["cmux hooks qoder"],
            currentMarkers: ["CMUX_AGENT_HOOK_VERSION=1"],
            isClaudeWrapper: false
        ),
    ]

    static func promptEnabled(defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: promptEnabledKey) == nil {
            return defaultPromptEnabled
        }
        return defaults.bool(forKey: promptEnabledKey)
    }

    static func setPromptEnabled(_ enabled: Bool, defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: promptEnabledKey)
        NotificationCenter.default.post(name: statusDidChangeNotification, object: nil)
    }

    static func agent(named name: String) -> AgentHookIntegration? {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return allAgents.first { agent in
            agent.name == normalized || agent.commandNames.contains(normalized)
        }
    }

    static func status(for agent: AgentHookIntegration, defaults: UserDefaults = .standard) -> AgentHookIntegrationStatus {
        configFileWatcher.startIfNeeded()

        if agent.isClaudeWrapper {
            return ClaudeCodeIntegrationSettings.hooksEnabled(defaults: defaults) ? .enabled : .disabled
        }

        guard let path = configFilePath(for: agent) else {
            return .notInstalled(path: nil)
        }

        guard FileManager.default.fileExists(atPath: path) else {
            return .notInstalled(path: path)
        }
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else {
            return .unreadable(path: path)
        }
        if agent.currentMarkers.contains(where: { contents.contains($0) }) {
            return .installed(path: path)
        }
        if agent.hookMarkers.contains(where: { contents.contains($0) }) {
            return .updateAvailable(path: path)
        }
        return .notInstalled(path: path)
    }

    static func statusLabel(for status: AgentHookIntegrationStatus) -> String {
        switch status {
        case .enabled:
            return String(localized: "settings.automation.agentHooks.status.enabled", defaultValue: "Enabled")
        case .disabled:
            return String(localized: "settings.automation.agentHooks.status.disabled", defaultValue: "Disabled")
        case .installed:
            return String(localized: "settings.automation.agentHooks.status.installed", defaultValue: "Installed")
        case .updateAvailable:
            return String(localized: "settings.automation.agentHooks.status.updateAvailable", defaultValue: "Update available")
        case .notInstalled:
            return String(localized: "settings.automation.agentHooks.status.notInstalled", defaultValue: "Not installed")
        case .unreadable, .unknown:
            return String(localized: "settings.automation.agentHooks.status.unknown", defaultValue: "Unknown")
        }
    }

    static func statusSubtitle(for agent: AgentHookIntegration, status: AgentHookIntegrationStatus) -> String {
        switch status {
        case .enabled:
            return String(localized: "settings.automation.agentHooks.status.claudeEnabled", defaultValue: "cmux wraps the claude command in cmux terminals.")
        case .disabled:
            return String(localized: "settings.automation.agentHooks.status.claudeDisabled", defaultValue: "Claude Code runs without cmux hooks.")
        case .installed(let path):
            return String(localized: "settings.automation.agentHooks.status.installedAt", defaultValue: "cmux hooks found in \(path).")
        case .updateAvailable:
            return String(localized: "settings.automation.agentHooks.status.updateAvailable.subtitle", defaultValue: "cmux hooks are installed, but this app has a newer hook script.")
        case .notInstalled:
            return String(localized: "settings.automation.agentHooks.status.notInstalled.subtitle", defaultValue: "No cmux hooks found.")
        case .unreadable(let path):
            return String(localized: "settings.automation.agentHooks.status.unreadable", defaultValue: "Could not read \(path).")
        case .unknown:
            return String(localized: "settings.automation.agentHooks.status.unknown", defaultValue: "Unknown")
        }
    }

    @MainActor
    static func showSetupPromptIfNeeded(agentName: String, tabId: UUID, surfaceId: UUID?) {
        guard promptEnabled(),
              let agent = agent(named: agentName),
              !TerminalNotificationStore.shared.hasAgentHookSetupNotification(for: agent.name) else {
            return
        }

        Task.detached(priority: .utility) {
            let currentStatus = status(for: agent)
            guard !currentStatus.isActive,
                  shouldShowPrompt(for: agent, status: currentStatus) else {
                return
            }

            await MainActor.run {
                guard promptEnabled(),
                      !TerminalNotificationStore.shared.hasAgentHookSetupNotification(for: agent.name) else {
                    return
                }

                TerminalNotificationStore.shared.addNotification(
                    tabId: tabId,
                    surfaceId: surfaceId,
                    title: currentStatus.isUpdateAvailable
                        ? String(localized: "agentHooks.nudge.updateTitle", defaultValue: "Update \(agent.displayName) hooks")
                        : String(localized: "agentHooks.nudge.title", defaultValue: "Install \(agent.displayName) hooks"),
                    subtitle: String(localized: "agentHooks.nudge.subtitle", defaultValue: "Notifications and session restore"),
                    body: currentStatus.isUpdateAvailable
                        ? String(localized: "agentHooks.nudge.updateBody", defaultValue: "cmux has a newer hook script for notifications and session restore.")
                        : String(localized: "agentHooks.nudge.body", defaultValue: "Hooks let cmux show agent notifications and restore sessions after cmux restarts."),
                    action: .agentHookSetup(agentName: agent.name)
                )
                AppDelegate.shared?.showNotificationsPopover(animated: true)
            }
        }
    }

    static func snoozePrompt(agentName: String, defaults: UserDefaults = .standard) {
        guard let agent = agent(named: agentName) else { return }
        let currentStatus = status(for: agent, defaults: defaults)
        markPromptSnoozed(for: agent, status: currentStatus, defaults: defaults)
    }

    static func installHooks(for agent: AgentHookIntegration, completion: @escaping (AgentHookInstallResult) -> Void) {
        if agent.isClaudeWrapper {
            UserDefaults.standard.set(true, forKey: ClaudeCodeIntegrationSettings.hooksEnabledKey)
            NotificationCenter.default.post(name: statusDidChangeNotification, object: nil)
            completion(AgentHookInstallResult(
                succeeded: true,
                message: String(localized: "settings.automation.agentHooks.status.claudeEnabled", defaultValue: "cmux wraps the claude command in cmux terminals.")
            ))
            return
        }

        let launch = hookInstallLaunch(for: agent)
        DispatchQueue.global(qos: .userInitiated).async {
            let result = runInstallCommand(
                executableURL: launch.executableURL,
                arguments: launch.arguments,
                environment: nil,
                fallbackCommand: agent.installCommand
            )
            DispatchQueue.main.async {
                configFileWatcher.refreshWatchedPaths()
                NotificationCenter.default.post(name: statusDidChangeNotification, object: nil)
                completion(result)
            }
        }
    }

    static func diffHooks(for agent: AgentHookIntegration, completion: @escaping (AgentHookDiffResult) -> Void) {
        if agent.isClaudeWrapper {
            completion(AgentHookDiffResult(
                succeeded: true,
                message: "",
                diff: String(localized: "agentHooks.diff.claude", defaultValue: "Claude Code uses the cmux wrapper in cmux terminals. No config file changes are needed.")
            ))
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            let result = buildHookDiff(for: agent)
            DispatchQueue.main.async {
                completion(result)
            }
        }
    }

    static func configDirectoryPath(for agent: AgentHookIntegration) -> String? {
        guard let configDir = agent.configDir else {
            return nil
        }
        if let envKey = agent.configDirEnvOverride,
           let envValue = ProcessInfo.processInfo.environment[envKey],
           !envValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return NSString(string: envValue).expandingTildeInPath
        }
        return NSString(string: "~/\(configDir)").expandingTildeInPath
    }

    static func configFilePath(for agent: AgentHookIntegration) -> String? {
        guard let directory = configDirectoryPath(for: agent),
              let configFile = agent.configFile else {
            return nil
        }
        return (directory as NSString).appendingPathComponent(configFile)
    }

    private static func shouldShowPrompt(
        for agent: AgentHookIntegration,
        status: AgentHookIntegrationStatus,
        defaults: UserDefaults = .standard
    ) -> Bool {
        let key = lastPromptKey(for: agent, status: status)
        let lastSnoozed = defaults.double(forKey: key)
        guard lastSnoozed > 0 else { return true }
        return Date().timeIntervalSince1970 - lastSnoozed >= promptCooldown
    }

    private static func markPromptSnoozed(
        for agent: AgentHookIntegration,
        status: AgentHookIntegrationStatus,
        defaults: UserDefaults = .standard
    ) {
        defaults.set(Date().timeIntervalSince1970, forKey: lastPromptKey(for: agent, status: status))
    }

    private static func lastPromptKey(for agent: AgentHookIntegration, status: AgentHookIntegrationStatus) -> String {
        let kind = status.isUpdateAvailable ? "update" : "install"
        return "agentHookSetupPromptSnoozedAt.\(agent.name).\(kind)"
    }

    static func hookInstallLaunch(for agent: AgentHookIntegration) -> (executableURL: URL, arguments: [String]) {
        if let bundledCLIURL = bundledCLIURLFromEnvironment() {
            return (bundledCLIURL, ["hooks", agent.name, "install", "--yes"])
        }
        if let bundledCLIURL = Bundle.main.resourceURL?.appendingPathComponent("bin/cmux"),
           executableFileURL(atPath: bundledCLIURL.path) != nil {
            return (bundledCLIURL, ["hooks", agent.name, "install", "--yes"])
        }
        return (URL(fileURLWithPath: "/usr/bin/env"), ["cmux", "hooks", agent.name, "install", "--yes"])
    }

    private static func bundledCLIURLFromEnvironment() -> URL? {
        guard let path = ProcessInfo.processInfo.environment["CMUX_BUNDLED_CLI_PATH"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty else {
            return nil
        }
        return executableFileURL(atPath: NSString(string: path).expandingTildeInPath)
    }

    private static func executableFileURL(atPath path: String) -> URL? {
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              !isDirectory.boolValue,
              FileManager.default.isExecutableFile(atPath: path) else {
            return nil
        }
        return URL(fileURLWithPath: path)
    }
}
