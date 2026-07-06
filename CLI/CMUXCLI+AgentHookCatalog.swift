import Foundation

extension CMUXCLI {
    // MARK: Agent definitions

    static let agentDefs: [AgentHookDef] = [
        AgentHookDef(
            name: "codex", displayName: "Codex", statusKey: "codex",
            configDir: ".codex", configFile: "hooks.json", configDirEnvOverride: "CODEX_HOME",
            sessionStoreSuffix: "codex", disableEnvVar: "CMUX_CODEX_HOOKS_DISABLED",
            hookMarker: "cmux hooks codex", format: .nested(timeoutMs: 5),
            events: [
                .init(agentEvent: "SessionStart", cmuxSubcommand: "session-start"),
                .init(agentEvent: "UserPromptSubmit", cmuxSubcommand: "prompt-submit"),
                .init(agentEvent: "Stop", cmuxSubcommand: "stop"),
            ],
            feedHookEvents: [
                "PreToolUse",
                "PermissionRequest",
                "PostToolUse",
                "PreCompact",
                "PostCompact",
                "SubagentStart",
                "SubagentStop",
            ],
            postInstallAction: .codexConfigToml
        ),
        AgentHookDef(
            name: "grok", displayName: "Grok", statusKey: "grok",
            configDir: ".grok/hooks", configFile: "cmux-session.json",
            configDirEnvOverride: "GROK_HOME", configDirEnvOverrideSubpath: "hooks",
            createConfigDirIfMissing: true,
            sessionStoreSuffix: "grok", disableEnvVar: "CMUX_GROK_HOOKS_DISABLED",
            hookMarker: "cmux hooks grok", format: .nested(timeoutMs: 5000),
            events: [
                .init(agentEvent: "SessionStart", cmuxSubcommand: "session-start"),
                .init(agentEvent: "UserPromptSubmit", cmuxSubcommand: "prompt-submit"),
                .init(agentEvent: "Stop", cmuxSubcommand: "stop"),
                .init(agentEvent: "Notification", cmuxSubcommand: "notification"),
                .init(agentEvent: "SessionEnd", cmuxSubcommand: "session-end"),
            ],
            publishesStopNotification: false,
            sessionEndIsTurnBoundary: true,
            feedHookEvents: ["PreToolUse"]
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
            name: "omp", displayName: "OMP", statusKey: "omp",
            configDir: ".omp/agent", configFile: "extensions/cmux-omp-session.ts",
            createConfigDirIfMissing: true,
            configDirResolver: { CMUXCLI.resolvedOmpAgentDirectory().path },
            sessionStoreSuffix: "omp", disableEnvVar: "CMUX_OMP_HOOKS_DISABLED",
            hookMarker: "cmux hooks omp", format: .flat,
            events: []
        ),
        AgentHookDef(
            name: "amp", displayName: "Amp", statusKey: "amp",
            configDir: ".config/amp", configFile: "plugins/cmux-session.ts",
            sessionStoreSuffix: "amp", disableEnvVar: "CMUX_AMP_HOOKS_DISABLED",
            hookMarker: "cmux hooks amp", format: .flat,
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
            name: "kiro", displayName: "Kiro", statusKey: "kiro",
            configDir: ".kiro/agents", configFile: "cmux.json",
            configDirEnvOverride: "KIRO_HOME", configDirEnvOverrideSubpath: "agents",
            createConfigDirIfMissing: true, binaryName: "kiro-cli",
            sessionStoreSuffix: "kiro", disableEnvVar: "CMUX_KIRO_HOOKS_DISABLED",
            hookMarker: "cmux hooks kiro", format: .kiroAgentJSON(timeoutMs: 5000),
            events: [
                .init(agentEvent: "agentSpawn", cmuxSubcommand: "session-start"),
                .init(agentEvent: "userPromptSubmit", cmuxSubcommand: "prompt-submit"),
                .init(agentEvent: "stop", cmuxSubcommand: "stop"),
            ],
            feedHookEvents: ["preToolUse", "postToolUse"],
            postInstallNote: String(
                localized: "cli.hooks.kiro.postInstallNote",
                defaultValue: "Kiro applies these hooks only when run as the cmux agent. Start Kiro with `kiro-cli chat --agent cmux`, or make it the default with `kiro-cli settings chat.defaultAgent cmux`."
            )
        ),
        AgentHookDef(
            name: "antigravity", displayName: "Antigravity", statusKey: "antigravity",
            configDir: ".gemini/config", configFile: "hooks.json",
            createConfigDirIfMissing: true, binaryName: "agy",
            sessionStoreSuffix: "antigravity", disableEnvVar: "CMUX_ANTIGRAVITY_HOOKS_DISABLED",
            hookMarker: "cmux hooks antigravity", format: .antigravityJSON(timeoutSeconds: 10),
            events: [
                .init(agentEvent: "SessionStart", cmuxSubcommand: "session-start"),
                .init(agentEvent: "PreInvocation", cmuxSubcommand: "prompt-submit"),
                .init(agentEvent: "Stop", cmuxSubcommand: "stop"),
                .init(agentEvent: "turn-completion", cmuxSubcommand: "stop"),
                .init(agentEvent: "Notification", cmuxSubcommand: "notification"),
                .init(agentEvent: "SessionEnd", cmuxSubcommand: "session-end"),
            ],
            aliases: ["agy"],
            sessionEndIsTurnBoundary: true,
            feedHookEvents: ["PreToolUse", "PostToolUse"]
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
                .init(agentEvent: "pre_approval_request", cmuxSubcommand: "notification"),
                .init(agentEvent: "post_approval_response", cmuxSubcommand: "approval-response"),
                .init(agentEvent: "on_session_end", cmuxSubcommand: "session-end"),
                .init(agentEvent: "on_session_finalize", cmuxSubcommand: "session-finalize"),
                .init(agentEvent: "on_session_reset", cmuxSubcommand: "session-start"),
            ],
            sessionEndIsTurnBoundary: true,
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
        AgentHookDef(
            name: "kimi", displayName: "Kimi Code", statusKey: "kimi",
            configDir: ".kimi-code", configFile: "config.toml", configDirEnvOverride: "KIMI_CODE_HOME",
            binaryName: "kimi",
            sessionStoreSuffix: "kimi", disableEnvVar: "CMUX_KIMI_HOOKS_DISABLED",
            hookMarker: "cmux hooks kimi", format: .tomlArrayTable,
            events: [
                .init(agentEvent: "SessionStart", cmuxSubcommand: "session-start"),
                .init(agentEvent: "UserPromptSubmit", cmuxSubcommand: "prompt-submit"),
                .init(agentEvent: "PermissionRequest", cmuxSubcommand: "notification"),
                .init(agentEvent: "Stop", cmuxSubcommand: "stop"),
                .init(agentEvent: "StopFailure", cmuxSubcommand: "notification"),
                .init(agentEvent: "Interrupt", cmuxSubcommand: "stop"),
                .init(agentEvent: "SessionEnd", cmuxSubcommand: "session-end"),
            ],
            feedHookEvents: ["PreToolUse", "PostToolUse", "PermissionRequest"]
        ),
    ]

    static func agentDef(named name: String) -> AgentHookDef? {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return agentDefs.first { $0.name == normalized || $0.aliases.contains(normalized) }
    }
}
