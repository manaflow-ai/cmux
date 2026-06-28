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
        let configDirEnvOverrideSubpath: String? // e.g. "GROK_HOME" + "hooks"
        let createConfigDirIfMissing: Bool // for agents whose hook dir is created lazily
        let configDirResolver: (@Sendable () -> String)?
        let sessionStoreSuffix: String // e.g. "cursor" -> ~/.cmuxterm/cursor-hook-sessions.json
        let disableEnvVar: String   // e.g. "CMUX_CURSOR_HOOKS_DISABLED"
        let hookMarker: String      // Marker in commands: "cmux hooks cursor"
        let binaryName: String
        let format: HookFormat
        let events: [HookEvent]
        let aliases: Set<String>
        let publishesStopNotification: Bool
        /// Whether this agent's `SessionEnd`/`session-end` hook fires once per
        /// conversation turn rather than at a true session teardown.
        ///
        /// Restorable agents (grok, antigravity, hermes-agent) re-emit their
        /// session-end event after every turn, so the `.sessionEnd` handler must
        /// treat it as a non-destructive turn boundary (`recordPromptStop`) and
        /// must not consume the session or clear the surface resume binding —
        /// otherwise the restore record is destroyed after the first turn and
        /// nothing survives a quit/relaunch. See
        /// https://github.com/manaflow-ai/cmux/issues/5000.
        ///
        /// Agents whose runtime distinguishes a per-turn boundary from a genuine
        /// session teardown (hermes-agent emits both `on_session_end` per turn and
        /// `on_session_finalize` once at the end) route the teardown event to the
        /// separate `session-finalize` subcommand / ``AgentHookAction/sessionFinalize``
        /// action, which performs the destructive cleanup this flag suppresses.
        let sessionEndIsTurnBoundary: Bool
        /// Feed-hook events. Each entry installs a second hook for
        /// `agentEvent` that invokes `cmux hooks feed --source <name>`
        /// with a 120s timeout so the socket reply wait doesn't trip the
        /// agent's default hook timeout when the user takes time to
        /// approve/deny a permission / plan / question.
        let feedHookEvents: [String]
        let postInstallAction: PostInstallAction?
        /// Optional CLI note printed after a successful install (or
        /// "already up to date") to guide a required activation step — e.g.
        /// Kiro applies its hooks only when run as the `cmux` agent.
        let postInstallNote: String?

        enum HookFormat {
            case flat       // Cursor: {"hooks": {"event": [{"command": "..."}]}, "version": 1}
            case nested(timeoutMs: Int)  // Nested type/command/timeout hooks; timeout unit is agent-specific.
            case kiroAgentJSON(timeoutMs: Int) // ~/.kiro/agents/*.json flat command entries with timeout_ms
            case antigravityJSON(timeoutSeconds: Int) // ~/.gemini/config/hooks.json named hook groups
            case rovoDevYAML
            case hermesAgentYAML
        }

        struct HookEvent {
            let agentEvent: String
            let cmuxSubcommand: String
        }

        enum PostInstallAction {
            case codexConfigToml // write hooks = true to config.toml on install, remove on uninstall
        }

        /// Resolves the config directory, respecting env override if set.
        func resolvedConfigDir() -> String {
            if let configDirResolver {
                return configDirResolver()
            }
            let home = ProcessInfo.processInfo.environment["HOME"].flatMap { value -> String? in
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            } ?? NSHomeDirectory()
            if let envKey = configDirEnvOverride,
               let rawEnvValue = ProcessInfo.processInfo.environment[envKey] {
                let envValue = rawEnvValue.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !envValue.isEmpty else {
                    return URL(fileURLWithPath: home, isDirectory: true)
                        .appendingPathComponent(configDir, isDirectory: true)
                        .path
                }
                var url = URL(fileURLWithPath: NSString(string: envValue).expandingTildeInPath, isDirectory: true)
                if let subpath = configDirEnvOverrideSubpath,
                   !subpath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    url.appendPathComponent(subpath, isDirectory: true)
                }
                return url.path
            }
            return URL(fileURLWithPath: home, isDirectory: true)
                .appendingPathComponent(configDir, isDirectory: true)
                .path
        }

        init(name: String, displayName: String, statusKey: String,
             configDir: String, configFile: String, configDirEnvOverride: String? = nil,
             configDirEnvOverrideSubpath: String? = nil,
             createConfigDirIfMissing: Bool = false,
             configDirResolver: (@Sendable () -> String)? = nil,
             binaryName: String? = nil,
             sessionStoreSuffix: String, disableEnvVar: String, hookMarker: String,
             format: HookFormat, events: [HookEvent],
             aliases: Set<String> = [],
             publishesStopNotification: Bool = true,
             sessionEndIsTurnBoundary: Bool = false,
             feedHookEvents: [String] = [],
             postInstallAction: PostInstallAction? = nil,
             postInstallNote: String? = nil) {
            self.name = name; self.displayName = displayName; self.statusKey = statusKey
            self.configDir = configDir; self.configFile = configFile
            self.configDirEnvOverride = configDirEnvOverride
            self.configDirEnvOverrideSubpath = configDirEnvOverrideSubpath
            self.createConfigDirIfMissing = createConfigDirIfMissing
            self.configDirResolver = configDirResolver
            self.binaryName = binaryName ?? name
            self.sessionStoreSuffix = sessionStoreSuffix; self.disableEnvVar = disableEnvVar
            self.hookMarker = hookMarker; self.format = format; self.events = events
            self.publishesStopNotification = publishesStopNotification
            self.sessionEndIsTurnBoundary = sessionEndIsTurnBoundary
            self.aliases = Set(aliases.compactMap { alias in
                let normalized = alias.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                return normalized.isEmpty ? nil : normalized
            })
            self.feedHookEvents = feedHookEvents
            self.postInstallAction = postInstallAction
            self.postInstallNote = postInstallNote
        }
    }

    enum AgentHookAction {
        case sessionStart, promptSubmit, stop, notification, approvalResponse, sessionEnd, sessionFinalize, noop
    }

    static let subcommandActions: [String: AgentHookAction] = [
        "session-start": .sessionStart,
        "prompt-submit": .promptSubmit,
        "stop": .stop,
        "notification": .notification,
        "notify": .notification,
        "agent-response": .stop,
        "approval-response": .approvalResponse,
        "shell-exec": .promptSubmit,
        "shell-done": .noop,
        "session-end": .sessionEnd,
        "session-finalize": .sessionFinalize,
    ]

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
            name: "campfire", displayName: "Campfire", statusKey: "campfire",
            configDir: ".campfire/agent", configFile: "extensions/cmux-campfire-session.ts",
            createConfigDirIfMissing: true,
            configDirResolver: { CMUXCLI.resolvedCampfireAgentDirectory().path },
            sessionStoreSuffix: "campfire", disableEnvVar: "CMUX_CAMPFIRE_HOOKS_DISABLED",
            hookMarker: "cmux hooks campfire", format: .flat,
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
    ]

    static func agentDef(named name: String) -> AgentHookDef? {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return agentDefs.first { $0.name == normalized || $0.aliases.contains(normalized) }
    }

    static func hookCommandString(for def: AgentHookDef, event: AgentHookDef.HookEvent) -> String {
        let command = "cmux hooks \(def.name) \(event.cmuxSubcommand)"
        let inline: String
        if def.name == "codex", codexHookCanRunFireAndForget(event.cmuxSubcommand) {
            inline = codexFireAndForgetAgentHookShellCommand(command, for: def)
        } else {
            inline = agentHookShellCommand(command, for: def)
        }
        if def.name == "codex" {
            return codexPersistentHookScriptCommand(inline, eventTag: event.cmuxSubcommand)
        }
        return inline
    }

    /// Wraps a codex persistent hook command as a `#!/bin/sh` script file in the
    /// cmux-owned hooks dir and returns its path. A bare executable path runs
    /// correctly under any runtime, including ones (subrouters/proxies) that exec
    /// the `command` string directly and fail an inline shell snippet with
    /// "No such file or directory (os error 2)". Falls back to the inline command
    /// on any write failure, so the persistent install can never regress.
    private static func codexPersistentHookScriptCommand(_ inlineCommand: String, eventTag: String) -> String {
        guard let dir = codexHookScriptsDirectory(),
              let path = writeCodexHookScript(
                  subcommand: "persistent-\(eventTag)", body: inlineCommand, in: dir
              ) else {
            return inlineCommand
        }
        return path
    }

    private static func codexHookCanRunFireAndForget(_ subcommand: String) -> Bool {
        subcommand == "session-start" || subcommand == "prompt-submit"
    }

    static func feedHookCommandString(for def: AgentHookDef, agentEvent: String) -> String {
        let inline: String
        let noOpCommand = feedHookNoOpShellCommand(for: def, agentEvent: agentEvent)
        switch def.format {
        case .kiroAgentJSON:
            inline = exitTwoPropagatingAgentHookShellCommand(
                "cmux hooks feed --source \(def.name) --event \(agentEvent)",
                for: def,
                noOpCommand: noOpCommand
            )
        default:
            inline = agentHookShellCommand(
                "cmux hooks feed --source \(def.name) --event \(agentEvent)",
                for: def,
                noOpCommand: noOpCommand
            )
        }
        if def.name == "codex" {
            return codexPersistentHookScriptCommand(inline, eventTag: "feed-\(agentEvent)")
        }
        return inline
    }

    private static func feedHookNoOpShellCommand(for def: AgentHookDef, agentEvent: String) -> String {
        let normalized = (def.name == "codex" ? "posttooluse" : agentEvent)
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
            .lowercased()
        switch normalized {
        case "posttooluse", "posttoolcall":
            return "cat >/dev/null 2>/dev/null || true; echo '{}'"
        default:
            return "echo '{}'"
        }
    }

    private static func shellNoOpSnippet(_ noOpCommand: String) -> String {
        noOpCommand == "echo '{}'" ? noOpCommand : "{ \(noOpCommand); }"
    }

    private static let grokPinnedHookMarker = "cmux-grok-hook-v2"
    private static let antigravityPinnedHookMarker = "cmux-antigravity-hook-v2"

    private static func agentHookShellCommand(
        _ command: String,
        for def: AgentHookDef,
        noOpCommand: String = "echo '{}'"
    ) -> String {
        if usesPinnedHookDispatch(def) {
            return pinnedAgentHookShellCommand(command, for: def, noOpCommand: noOpCommand)
        }
        let routedArguments = command.hasPrefix("cmux ") ? String(command.dropFirst("cmux ".count)) : command
        let noOpSnippet = shellNoOpSnippet(noOpCommand)
        return "cmux_cli=\"${CMUX_BUNDLED_CLI_PATH:-}\"; if [ -z \"$cmux_cli\" ] || [ ! -x \"$cmux_cli\" ]; then cmux_cli=\"$(command -v cmux 2>/dev/null || true)\"; fi; if [ -n \"$CMUX_SURFACE_ID\" ] && [ \"$\(def.disableEnvVar)\" != \"1\" ] && [ -n \"$cmux_cli\" ]; then { if [ -n \"${CMUX_SOCKET_PATH:-}\" ]; then \"$cmux_cli\" --socket \"$CMUX_SOCKET_PATH\" \(routedArguments); else \"$cmux_cli\" \(routedArguments); fi; } || \(noOpSnippet); else \(noOpSnippet); fi"
    }

    private static func exitTwoPropagatingAgentHookShellCommand(
        _ command: String,
        for def: AgentHookDef,
        noOpCommand: String = "echo '{}'"
    ) -> String {
        let routedArguments = command.hasPrefix("cmux ") ? String(command.dropFirst("cmux ".count)) : command
        let noOpSnippet = shellNoOpSnippet(noOpCommand)
        return "cmux_cli=\"${CMUX_BUNDLED_CLI_PATH:-}\"; if [ -z \"$cmux_cli\" ] || [ ! -x \"$cmux_cli\" ]; then cmux_cli=\"$(command -v cmux 2>/dev/null || true)\"; fi; if [ -n \"$CMUX_SURFACE_ID\" ] && [ \"$\(def.disableEnvVar)\" != \"1\" ] && [ -n \"$cmux_cli\" ]; then if [ -n \"${CMUX_SOCKET_PATH:-}\" ]; then \"$cmux_cli\" --socket \"$CMUX_SOCKET_PATH\" \(routedArguments); else \"$cmux_cli\" \(routedArguments); fi; status=$?; if [ \"$status\" -eq 2 ]; then exit 2; fi; if [ \"$status\" -ne 0 ]; then \(noOpSnippet); fi; else \(noOpSnippet); fi"
    }

    private static func usesPinnedHookDispatch(_ def: AgentHookDef) -> Bool {
        def.name == "grok" || def.name == "antigravity"
    }

    private static func pinnedHookMarker(for def: AgentHookDef) -> String {
        def.name == "antigravity" ? antigravityPinnedHookMarker : grokPinnedHookMarker
    }

    private static func pinnedAgentHookShellCommand(
        _ command: String,
        for def: AgentHookDef,
        noOpCommand: String = "echo '{}'"
    ) -> String {
        let routedArguments = command.hasPrefix("cmux ") ? String(command.dropFirst("cmux ".count)) : command
        let socketPath = pinnedAgentHookSocketPath()
        let noOpSnippet = shellNoOpSnippet(noOpCommand)
        let shellTraceStart = pinnedHookShellTraceCommand(
            agentName: def.name,
            phase: "start",
            routedArguments: routedArguments,
            socketPath: socketPath
        )
        let shellTraceDisabled = pinnedHookShellTraceCommand(
            agentName: def.name,
            phase: "disabled",
            routedArguments: routedArguments,
            socketPath: socketPath
        )
        let shellTraceExit = pinnedHookShellTraceCommand(
            agentName: def.name,
            phase: "exit",
            routedArguments: routedArguments,
            socketPath: socketPath,
            statusExpression: "$cmux_hook_status"
        )
        let fallbackInvocation = pinnedHookInvocation(
            executable: "cmux",
            routedArguments: routedArguments,
            socketPath: socketPath
        )
        let dispatch: String
        if let cliPath = pinnedAgentHookCLIPath() {
            let quotedCLIPath = shellSingleQuote(cliPath)
            let primaryInvocation = pinnedHookInvocation(
                executable: quotedCLIPath,
                routedArguments: routedArguments,
                socketPath: socketPath
            )
            dispatch = "if [ -x \(quotedCLIPath) ]; then \(primaryInvocation); elif command -v cmux >/dev/null 2>&1; then \(fallbackInvocation); else \(noOpSnippet); fi"
        } else {
            dispatch = "command -v cmux >/dev/null 2>&1 && \(fallbackInvocation) || \(noOpSnippet)"
        }
        return ": \(pinnedHookMarker(for: def)); \(shellTraceStart); printenv \(def.disableEnvVar) | grep -qx 1 && { \(shellTraceDisabled); \(noOpCommand); } || { \(dispatch); cmux_hook_status=$?; \(shellTraceExit); exit $cmux_hook_status; }"
    }

    private static func pinnedHookInvocation(
        executable: String,
        routedArguments: String,
        socketPath: String?
    ) -> String {
        if let socketPath {
            return "\(executable) --socket \(shellSingleQuote(socketPath)) \(routedArguments)"
        }
        return "\(executable) \(routedArguments)"
    }

    private static func pinnedAgentHookCLIPath(
        env: [String: String] = ProcessInfo.processInfo.environment,
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> String? {
        if let bundledPath = normalizedHookInstallValue(env["CMUX_BUNDLED_CLI_PATH"]) {
            let expanded = NSString(string: bundledPath).expandingTildeInPath
            if isExecutableFilePath(expanded) {
                return expanded
            }
        }
        if let arg0 = normalizedHookInstallValue(arguments.first) {
            let expanded = NSString(string: arg0).expandingTildeInPath
            if expanded.hasPrefix("/"), isExecutableFilePath(expanded) {
                return expanded
            }
        }
        if let executablePath = Bundle.main.executableURL?.path,
           !executablePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           isExecutableFilePath(executablePath) {
            return executablePath
        }
        return nil
    }

    private static func isExecutableFilePath(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              !isDirectory.boolValue
        else {
            return false
        }
        return FileManager.default.isExecutableFile(atPath: path)
    }

    private static func pinnedAgentHookSocketPath(
        env: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        if let socketPath = normalizedHookInstallValue(env["CMUX_SOCKET_PATH"]) {
            return NSString(string: socketPath).expandingTildeInPath
        }
        guard let tag = normalizedHookInstallValue(env["CMUX_TAG"]) else {
            return nil
        }
        let slug = tag
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        guard !slug.isEmpty else { return nil }
        return "/tmp/cmux-debug-\(slug).sock"
    }

    private static func pinnedHookShellTraceCommand(
        agentName: String,
        phase: String,
        routedArguments: String,
        socketPath: String?,
        statusExpression: String? = nil
    ) -> String {
#if DEBUG
        let logPath = shellSingleQuote(pinnedHookShellTraceLogPath(socketPath: socketPath))
        let event = shellSingleQuote(routedArguments)
        let socket = shellSingleQuote(socketPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "nil")
        let statusField = statusExpression == nil ? "" : " status=%s"
        let statusArgument = statusExpression.map { " \($0)" } ?? ""
        return "printf '%s \(agentName)Hook.shell phase=%s event=%s pid=%s ppid=%s socket=%s\(statusField)\\n' \"$(date +%s)\" \(shellSingleQuote(phase)) \(event) \"$$\" \"${PPID:-}\" \(socket)\(statusArgument) >> \(logPath) 2>/dev/null || true"
#else
        return ":"
#endif
    }

    private static func pinnedHookShellTraceLogPath(socketPath: String?) -> String {
        guard let socketPath else {
            return "/tmp/cmux-debug.log"
        }
        let socketName = URL(fileURLWithPath: socketPath).lastPathComponent
        if socketName.hasPrefix("cmux-debug-"), socketName.hasSuffix(".sock") {
            return URL(fileURLWithPath: "/tmp", isDirectory: true)
                .appendingPathComponent(String(socketName.dropLast(".sock".count)) + ".log")
                .path
        }
        return "/tmp/cmux-debug.log"
    }

    private static func normalizedHookInstallValue(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private static func shellSingleQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func isCmuxOwnedHookCommand(_ command: String, for def: AgentHookDef, includeLegacy: Bool = true) -> Bool {
        if usesPinnedHookDispatch(def), command.contains(pinnedHookMarker(for: def)) {
            return true
        }
        if def.events.contains(where: { hookCommandString(for: def, event: $0) == command })
            || def.feedHookEvents.contains(where: { feedHookCommandString(for: def, agentEvent: $0) == command })
        {
            return true
        }
        return includeLegacy && isLegacyCmuxOwnedHookCommand(command, for: def)
    }

    private static func isLegacyCmuxOwnedHookCommand(_ command: String, for def: AgentHookDef) -> Bool {
        // Codex also had older top-level codex-hook/feed-hook commands.
        // Other generic agents can have stale `cmux hooks ...` files from
        // earlier integration attempts, and setup should be able to prune them.
        return legacyCmuxCommandTokenLists(from: command, for: def).contains { tokens in
            isLegacyCmuxOwnedHookTokens(tokens, for: def)
        }
    }

    private static func isLegacyCmuxOwnedHookTokens(_ tokens: [String], for def: AgentHookDef) -> Bool {
        guard !tokens.isEmpty,
              URL(fileURLWithPath: tokens[0]).lastPathComponent == "cmux"
        else {
            return false
        }

        if def.name == "codex", tokens.count >= 2, tokens[1] == "codex-hook" {
            return true
        }
        if def.name == "codex",
           tokens.count >= 4,
           tokens[1] == "feed-hook",
           tokens[2] == "--source",
           tokens[3] == def.name {
            return true
        }
        if tokens.count >= 3, tokens[1] == "hooks", tokens[2] == def.name {
            return true
        }
        if tokens.count >= 5,
           tokens[1] == "hooks",
           tokens[2] == "feed",
           tokens[3] == "--source",
           tokens[4] == def.name {
            return true
        }
        return false
    }

    private static func legacyCmuxCommandTokenLists(from command: String, for def: AgentHookDef) -> [[String]] {
        if let bundledTokens = bundledCLICmuxCommandTokenLists(from: command), !bundledTokens.isEmpty {
            return bundledTokens
        }

        let guardedPrefixes = [
            "[ -n \"$CMUX_SURFACE_ID\" ] && [ \"$\(def.disableEnvVar)\" != \"1\" ] && command -v cmux >/dev/null 2>&1 && ",
            "[ \"$\(def.disableEnvVar)\" != \"1\" ] && command -v cmux >/dev/null 2>&1 && ",
        ]
        let fallbackSuffix = " || echo '{}'"
        var body = command
        if def.name == "grok" {
            let grokPrefix = "printenv \(def.disableEnvVar) | grep -qx 1 && echo '{}' || { command -v cmux >/dev/null 2>&1 && "
            let grokSuffix = " || echo '{}'; }"
            if body.hasPrefix(grokPrefix), body.hasSuffix(grokSuffix) {
                body.removeFirst(grokPrefix.count)
                body.removeLast(grokSuffix.count)
                guard !body.contains(";"), !body.contains("|"), !body.contains("&"), !body.contains("`") else {
                    return []
                }
                return [body.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)]
            }
        }
        for guardedPrefix in guardedPrefixes where body.hasPrefix(guardedPrefix) {
            body.removeFirst(guardedPrefix.count)
            break
        }
        if body.hasSuffix(fallbackSuffix) {
            body.removeLast(fallbackSuffix.count)
        }
        guard !body.contains(";"), !body.contains("|"), !body.contains("&"), !body.contains("`") else {
            return []
        }
        return [body.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)]
    }

    private static func bundledCLICmuxCommandTokenLists(from command: String) -> [[String]]? {
        guard command.contains("CMUX_BUNDLED_CLI_PATH"),
              command.contains("cmux_cli="),
              command.contains("command -v cmux") else {
            return nil
        }

        let invocationPrefixes = [
            "\"$cmux_cli\" --socket \"$CMUX_SOCKET_PATH\" ",
            "\"$cmux_cli\" ",
        ]
        var tokenLists: [[String]] = []
        for prefix in invocationPrefixes {
            var searchStart = command.startIndex
            while let prefixRange = command.range(of: prefix, range: searchStart..<command.endIndex) {
                let argsStart = prefixRange.upperBound
                let tail = command[argsStart..<command.endIndex]
                let argsEnd = [
                    tail.range(of: ";")?.lowerBound,
                    tail.range(of: " ||")?.lowerBound,
                    tail.range(of: " &&")?.lowerBound,
                    tail.range(of: " }")?.lowerBound,
                ].compactMap { $0 }.min() ?? command.endIndex
                let args = command[argsStart..<argsEnd].trimmingCharacters(in: .whitespacesAndNewlines)
                if !args.isEmpty,
                   !args.contains(";"),
                   !args.contains("|"),
                   !args.contains("&"),
                   !args.contains("`") {
                    tokenLists.append(
                        ["cmux"] + args.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
                    )
                }
                searchStart = prefixRange.upperBound
            }
        }
        return tokenLists
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
