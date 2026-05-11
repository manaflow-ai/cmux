import Foundation

extension CMUXCLI {
    // MARK: - Generic agent hook system

    /// Configuration for a hook-based agent integration.
    struct AgentHookDef {
        let name: String            // CLI name: "cursor", "gemini", etc.
        let displayName: String     // Human-readable: "Cursor", "Gemini"
        let statusKey: String       // Key for set_status: "cursor", "gemini"
        let configDir: String       // Relative to ~: ".cursor", ".gemini"
        let configFile: String      // File name: "hooks.json", "settings.json"
        let configDirEnvOverride: String? // e.g. "CODEX_HOME" overrides configDir
        let sessionStoreSuffix: String // e.g. "cursor" -> ~/.cmuxterm/cursor-hook-sessions.json
        let disableEnvVar: String   // e.g. "CMUX_CURSOR_HOOKS_DISABLED"
        let hookMarker: String      // Marker in commands: "cmux hooks cursor"
        let binaryName: String
        let format: HookFormat
        let events: [HookEvent]
        let aliases: Set<String>
        /// Feed-hook events. Each entry installs a second hook for
        /// `agentEvent` that invokes `cmux hooks feed --source <name>`
        /// with a 120s timeout so the socket reply wait doesn't trip the
        /// agent's default hook timeout when the user takes time to
        /// approve/deny a permission / plan / question.
        let feedHookEvents: [String]
        let postInstallAction: PostInstallAction?

        enum HookFormat {
            case flat       // Cursor: {"hooks": {"event": [{"command": "..."}]}, "version": 1}
            case nested(timeoutMs: Int)  // Codex/Gemini: nested with type/command/timeout
            case rovoDevYAML
            case hermesAgentYAML
        }

        struct HookEvent {
            let agentEvent: String
            let cmuxSubcommand: String
        }

        enum PostInstallAction {
            case codexConfigToml // write codex_hooks = true to config.toml on install, remove on uninstall
        }

        /// Resolves the config directory, respecting env override if set.
        func resolvedConfigDir() -> String {
            if let envKey = configDirEnvOverride,
               let envValue = ProcessInfo.processInfo.environment[envKey],
               !envValue.isEmpty {
                return NSString(string: envValue).expandingTildeInPath
            }
            let home = ProcessInfo.processInfo.environment["HOME"].flatMap { value -> String? in
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            } ?? NSHomeDirectory()
            return URL(fileURLWithPath: home, isDirectory: true)
                .appendingPathComponent(configDir, isDirectory: true)
                .path
        }

        init(name: String, displayName: String, statusKey: String,
             configDir: String, configFile: String, configDirEnvOverride: String? = nil,
             binaryName: String? = nil,
             sessionStoreSuffix: String, disableEnvVar: String, hookMarker: String,
             format: HookFormat, events: [HookEvent],
             aliases: Set<String> = [],
             feedHookEvents: [String] = [],
             postInstallAction: PostInstallAction? = nil) {
            self.name = name; self.displayName = displayName; self.statusKey = statusKey
            self.configDir = configDir; self.configFile = configFile
            self.configDirEnvOverride = configDirEnvOverride
            self.binaryName = binaryName ?? name
            self.sessionStoreSuffix = sessionStoreSuffix; self.disableEnvVar = disableEnvVar
            self.hookMarker = hookMarker; self.format = format; self.events = events
            self.aliases = Set(aliases.compactMap { alias in
                let normalized = alias.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                return normalized.isEmpty ? nil : normalized
            })
            self.feedHookEvents = feedHookEvents
            self.postInstallAction = postInstallAction
        }
    }

    enum AgentHookAction {
        case sessionStart, promptSubmit, stop, sessionEnd, noop
    }

    static let subcommandActions: [String: AgentHookAction] = [
        "session-start": .sessionStart,
        "prompt-submit": .promptSubmit,
        "stop": .stop,
        "agent-response": .stop,
        "shell-exec": .promptSubmit,
        "shell-done": .noop,
        "session-end": .sessionEnd,
    ]

    // MARK: Agent definitions

    static let agentDefs: [AgentHookDef] = [
        AgentHookDef(
            name: "codex", displayName: "Codex", statusKey: "codex",
            configDir: ".codex", configFile: "hooks.json", configDirEnvOverride: "CODEX_HOME",
            sessionStoreSuffix: "codex", disableEnvVar: "CMUX_CODEX_HOOKS_DISABLED",
            hookMarker: "cmux hooks codex", format: .nested(timeoutMs: 5000),
            events: [
                .init(agentEvent: "SessionStart", cmuxSubcommand: "session-start"),
                .init(agentEvent: "UserPromptSubmit", cmuxSubcommand: "prompt-submit"),
                .init(agentEvent: "Stop", cmuxSubcommand: "stop"),
            ],
            feedHookEvents: ["PreToolUse", "PermissionRequest"],
            postInstallAction: .codexConfigToml
        ),
        AgentHookDef(
            name: "opencode", displayName: "OpenCode", statusKey: "opencode",
            configDir: ".config/opencode", configFile: "plugins/cmux-session.js", configDirEnvOverride: "OPENCODE_CONFIG_DIR",
            sessionStoreSuffix: "opencode", disableEnvVar: "CMUX_OPENCODE_HOOKS_DISABLED",
            hookMarker: "cmux hooks opencode", format: .flat,
            events: []
        ),
        AgentHookDef(
            name: "pi", displayName: "Pi", statusKey: "pi",
            configDir: ".pi/agent", configFile: "extensions/cmux-session.ts", configDirEnvOverride: "PI_CODING_AGENT_DIR",
            sessionStoreSuffix: "pi", disableEnvVar: "CMUX_PI_HOOKS_DISABLED",
            hookMarker: "cmux hooks pi", format: .flat,
            events: []
        ),
        AgentHookDef(
            name: "cursor", displayName: "Cursor", statusKey: "cursor",
            configDir: ".cursor", configFile: "hooks.json", binaryName: "cursor-agent",
            sessionStoreSuffix: "cursor", disableEnvVar: "CMUX_CURSOR_HOOKS_DISABLED",
            hookMarker: "cmux hooks cursor", format: .flat,
            events: [
                .init(agentEvent: "beforeSubmitPrompt", cmuxSubcommand: "prompt-submit"),
                .init(agentEvent: "stop", cmuxSubcommand: "stop"),
                .init(agentEvent: "afterAgentResponse", cmuxSubcommand: "agent-response"),
                .init(agentEvent: "beforeShellExecution", cmuxSubcommand: "shell-exec"),
                .init(agentEvent: "afterShellExecution", cmuxSubcommand: "shell-done"),
            ],
            feedHookEvents: ["beforeShellExecution"]
        ),
        AgentHookDef(
            name: "gemini", displayName: "Gemini", statusKey: "gemini",
            configDir: ".gemini", configFile: "settings.json",
            sessionStoreSuffix: "gemini", disableEnvVar: "CMUX_GEMINI_HOOKS_DISABLED",
            hookMarker: "cmux hooks gemini", format: .nested(timeoutMs: 10000),
            events: [
                .init(agentEvent: "SessionStart", cmuxSubcommand: "session-start"),
                .init(agentEvent: "BeforeAgent", cmuxSubcommand: "prompt-submit"),
                .init(agentEvent: "AfterAgent", cmuxSubcommand: "stop"),
                .init(agentEvent: "SessionEnd", cmuxSubcommand: "session-end"),
            ],
            feedHookEvents: ["PreToolUse"]
        ),
        AgentHookDef(
            name: "rovodev", displayName: "Rovo Dev", statusKey: "rovodev",
            configDir: ".rovodev", configFile: "config.yml", binaryName: "acli",
            sessionStoreSuffix: "rovodev", disableEnvVar: "CMUX_ROVODEV_HOOKS_DISABLED",
            hookMarker: "cmux hooks rovodev", format: .rovoDevYAML,
            events: [
                .init(agentEvent: "on_complete", cmuxSubcommand: "stop"),
                .init(agentEvent: "on_error", cmuxSubcommand: "stop"),
                .init(agentEvent: "on_tool_permission", cmuxSubcommand: "prompt-submit"),
            ],
            aliases: ["rovo"]
        ),
        AgentHookDef(
            name: "hermes-agent", displayName: "Hermes Agent", statusKey: "hermes-agent",
            configDir: ".hermes", configFile: "config.yaml", configDirEnvOverride: "HERMES_HOME",
            binaryName: "hermes",
            sessionStoreSuffix: "hermes-agent", disableEnvVar: "CMUX_HERMES_AGENT_HOOKS_DISABLED",
            hookMarker: "cmux hooks hermes-agent", format: .hermesAgentYAML,
            events: [
                .init(agentEvent: "on_session_start", cmuxSubcommand: "session-start"),
                .init(agentEvent: "pre_llm_call", cmuxSubcommand: "prompt-submit"),
                .init(agentEvent: "post_llm_call", cmuxSubcommand: "agent-response"),
                .init(agentEvent: "on_session_end", cmuxSubcommand: "session-end"),
                .init(agentEvent: "on_session_finalize", cmuxSubcommand: "session-end"),
                .init(agentEvent: "on_session_reset", cmuxSubcommand: "session-start"),
            ],
            feedHookEvents: ["pre_tool_call", "post_tool_call", "pre_approval_request", "post_approval_response"]
        ),
        AgentHookDef(
            name: "copilot", displayName: "Copilot", statusKey: "copilot",
            configDir: ".copilot", configFile: "config.json", configDirEnvOverride: "COPILOT_HOME",
            sessionStoreSuffix: "copilot", disableEnvVar: "CMUX_COPILOT_HOOKS_DISABLED",
            hookMarker: "cmux hooks copilot", format: .nested(timeoutMs: 5000),
            events: [
                .init(agentEvent: "SessionStart", cmuxSubcommand: "session-start"),
                .init(agentEvent: "Stop", cmuxSubcommand: "stop"),
                .init(agentEvent: "Notification", cmuxSubcommand: "stop"),
                .init(agentEvent: "SessionEnd", cmuxSubcommand: "session-end"),
            ],
            feedHookEvents: ["PreToolUse"]
        ),
        AgentHookDef(
            name: "codebuddy", displayName: "CodeBuddy", statusKey: "codebuddy",
            configDir: ".codebuddy", configFile: "settings.json", configDirEnvOverride: "CODEBUDDY_CONFIG_DIR",
            sessionStoreSuffix: "codebuddy", disableEnvVar: "CMUX_CODEBUDDY_HOOKS_DISABLED",
            hookMarker: "cmux hooks codebuddy", format: .nested(timeoutMs: 5000),
            events: [
                .init(agentEvent: "SessionStart", cmuxSubcommand: "session-start"),
                .init(agentEvent: "Stop", cmuxSubcommand: "stop"),
                .init(agentEvent: "Notification", cmuxSubcommand: "stop"),
                .init(agentEvent: "SessionEnd", cmuxSubcommand: "session-end"),
            ],
            feedHookEvents: ["PreToolUse"]
        ),
        AgentHookDef(
            name: "factory", displayName: "Factory", statusKey: "factory",
            configDir: ".factory", configFile: "settings.json", binaryName: "droid",
            sessionStoreSuffix: "factory", disableEnvVar: "CMUX_FACTORY_HOOKS_DISABLED",
            hookMarker: "cmux hooks factory", format: .nested(timeoutMs: 5000),
            events: [
                .init(agentEvent: "SessionStart", cmuxSubcommand: "session-start"),
                .init(agentEvent: "Stop", cmuxSubcommand: "stop"),
                .init(agentEvent: "Notification", cmuxSubcommand: "stop"),
                .init(agentEvent: "SessionEnd", cmuxSubcommand: "session-end"),
            ],
            feedHookEvents: ["PreToolUse"]
        ),
        AgentHookDef(
            name: "qoder", displayName: "Qoder", statusKey: "qoder",
            configDir: ".qoder", configFile: "settings.json", configDirEnvOverride: "QODER_CONFIG_DIR", binaryName: "qodercli",
            sessionStoreSuffix: "qoder", disableEnvVar: "CMUX_QODER_HOOKS_DISABLED",
            hookMarker: "cmux hooks qoder", format: .nested(timeoutMs: 5000),
            events: [
                .init(agentEvent: "SessionStart", cmuxSubcommand: "session-start"),
                .init(agentEvent: "Stop", cmuxSubcommand: "stop"),
                .init(agentEvent: "SessionEnd", cmuxSubcommand: "session-end"),
            ],
            feedHookEvents: ["PreToolUse"]
        ),
    ]

    static func agentDef(named name: String) -> AgentHookDef? {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return agentDefs.first { $0.name == normalized || $0.aliases.contains(normalized) }
    }

    static func hookMarkers(for def: AgentHookDef) -> [String] {
        var markers = [def.hookMarker]
        if def.name == "codex" {
            markers.append("cmux codex-hook")
        }
        return markers
    }

    /// Marker substrings used when removing / upgrading our own Feed bridge
    /// entries on reinstall or uninstall.
    static func feedHookMarkers(for def: AgentHookDef) -> [String] {
        var markers = ["cmux hooks feed --source"]
        if def.name == "codex" {
            markers.append("cmux feed-hook --source")
        }
        return markers
    }
}
