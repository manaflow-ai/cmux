import Foundation

enum AgentHibernationHookSetupEvidence {
#if DEBUG
    static var hasHookSetupEvidenceHandlerForTests: ((UserDefaults) -> Bool)?
#endif

    static func hasHookSetupEvidence(
        defaults: UserDefaults = .standard,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> Bool {
#if DEBUG
        if let hasHookSetupEvidenceHandlerForTests {
            return hasHookSetupEvidenceHandlerForTests(defaults)
        }
#endif
        if ClaudeCodeIntegrationSettings.hooksEnabled(defaults: defaults),
           environment["CMUX_CLAUDE_HOOKS_DISABLED"]?.trimmingCharacters(in: .whitespacesAndNewlines) != "1" {
            return true
        }
        return hookSetupEvidenceDefinitions.contains { definition in
            guard definition.isActive(defaults: defaults, environment: environment) else {
                return false
            }
            let fileURL = definition.configURL(environment: environment, homeDirectory: homeDirectory)
            guard let contents = try? String(contentsOf: fileURL, encoding: .utf8) else {
                return false
            }
            return definition.matchesHookEvidence(in: contents)
        }
    }

    private static let hookSetupEvidenceDefinitions: [AgentHookSetupEvidenceDefinition] = [
        AgentHookSetupEvidenceDefinition(
            name: "codex",
            configDir: ".codex",
            configFile: "hooks.json",
            envOverride: "CODEX_HOME",
            disableEnvVar: "CMUX_CODEX_HOOKS_DISABLED",
            markers: ["cmux hooks codex", "cmux codex-hook"]
        ),
        AgentHookSetupEvidenceDefinition(
            name: "grok",
            configDir: ".grok/hooks",
            configFile: "cmux-session.json",
            envOverride: "GROK_HOME",
            envOverrideSubpath: "hooks",
            disableEnvVar: "CMUX_GROK_HOOKS_DISABLED",
            markers: ["cmux-grok-hook-v2", "cmux hooks grok"]
        ),
        AgentHookSetupEvidenceDefinition(
            name: "opencode",
            configDir: ".config/opencode",
            configFile: "plugins/cmux-session.js",
            envOverride: "OPENCODE_CONFIG_DIR",
            disableEnvVar: "CMUX_OPENCODE_HOOKS_DISABLED",
            markers: ["cmux hooks opencode"]
        ),
        AgentHookSetupEvidenceDefinition(
            name: "pi",
            configDir: ".pi/agent",
            configFile: "extensions/cmux-session.ts",
            envOverride: "PI_CODING_AGENT_DIR",
            disableEnvVar: "CMUX_PI_HOOKS_DISABLED",
            markers: ["cmux hooks pi"]
        ),
        AgentHookSetupEvidenceDefinition(
            name: "amp",
            configDir: ".config/amp",
            configFile: "plugins/cmux-session.ts",
            disableEnvVar: "CMUX_AMP_HOOKS_DISABLED",
            markers: ["cmux hooks amp"]
        ),
        AgentHookSetupEvidenceDefinition(
            name: "cursor",
            configDir: ".cursor",
            configFile: "hooks.json",
            disableEnvVar: "CMUX_CURSOR_HOOKS_DISABLED",
            markers: ["cmux hooks cursor"],
            isEnabled: { CursorIntegrationSettings.hooksEnabled(defaults: $0) }
        ),
        AgentHookSetupEvidenceDefinition(
            name: "gemini",
            configDir: ".gemini",
            configFile: "settings.json",
            disableEnvVar: "CMUX_GEMINI_HOOKS_DISABLED",
            markers: ["cmux hooks gemini"],
            isEnabled: { GeminiIntegrationSettings.hooksEnabled(defaults: $0) }
        ),
        AgentHookSetupEvidenceDefinition(
            name: "antigravity",
            configDir: ".gemini/config",
            configFile: "hooks.json",
            disableEnvVar: "CMUX_ANTIGRAVITY_HOOKS_DISABLED",
            markers: ["cmux-antigravity-hook-v2", "cmux hooks antigravity"]
        ),
        AgentHookSetupEvidenceDefinition(
            name: "rovodev",
            configDir: ".rovodev",
            configFile: "config.yml",
            disableEnvVar: "CMUX_ROVODEV_HOOKS_DISABLED",
            markers: ["cmux hooks rovodev"]
        ),
        AgentHookSetupEvidenceDefinition(
            name: "hermes-agent",
            configDir: ".hermes",
            configFile: "config.yaml",
            envOverride: "HERMES_HOME",
            disableEnvVar: "CMUX_HERMES_AGENT_HOOKS_DISABLED",
            markers: ["cmux hooks hermes-agent"]
        ),
        AgentHookSetupEvidenceDefinition(
            name: "copilot",
            configDir: ".copilot",
            configFile: "config.json",
            envOverride: "COPILOT_HOME",
            disableEnvVar: "CMUX_COPILOT_HOOKS_DISABLED",
            markers: ["cmux hooks copilot"]
        ),
        AgentHookSetupEvidenceDefinition(
            name: "codebuddy",
            configDir: ".codebuddy",
            configFile: "settings.json",
            envOverride: "CODEBUDDY_CONFIG_DIR",
            disableEnvVar: "CMUX_CODEBUDDY_HOOKS_DISABLED",
            markers: ["cmux hooks codebuddy"]
        ),
        AgentHookSetupEvidenceDefinition(
            name: "factory",
            configDir: ".factory",
            configFile: "settings.json",
            disableEnvVar: "CMUX_FACTORY_HOOKS_DISABLED",
            markers: ["cmux hooks factory"]
        ),
        AgentHookSetupEvidenceDefinition(
            name: "qoder",
            configDir: ".qoder",
            configFile: "settings.json",
            envOverride: "QODER_CONFIG_DIR",
            disableEnvVar: "CMUX_QODER_HOOKS_DISABLED",
            markers: ["cmux hooks qoder"]
        )
    ]
}
