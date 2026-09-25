import CMUXAgentLaunch
import Foundation

extension CMUXCLI {
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
        /// How installed hooks find the cmux instance that owns them.
        ///
        /// `.ambient` is appropriate when an agent preserves the launch environment. `.pinned`
        /// embeds the installing CLI and socket, which is required for agents that sanitize hook
        /// subprocess environments and keeps callbacks attributed to the correct tagged app.
        let dispatch: HookDispatch
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
        /// Whether repeated prompt-start callbacks represent one authoritative
        /// provider loop rather than independently balanced prompt frames.
        ///
        /// This is intentionally separate from `sessionEndIsTurnBoundary`:
        /// a provider may use `session-end` as a per-turn restore boundary while
        /// still emitting prompt starts/completions that must balance one at a
        /// time (for example Grok and Hermes Agent).
        let promptStartIsAuthoritative: Bool
        /// Events that install a `cmux hooks feed --source <name>` bridge.
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
            case tomlArrayTable // Kimi config.toml [[hooks]] array-of-tables
        }

        enum HookDispatch {
            case ambient
            case pinned(marker: String)
        }

        struct HookEvent {
            let agentEvent: String
            let cmuxSubcommand: String
            /// Catalog events are status/lifecycle telemetry. They must only
            /// transfer an immutable snapshot to the app queue; hooks whose
            /// output affects an agent decision live in `feedHookEvents` and
            /// continue to use the direct synchronous path.
            let delivery: HookDelivery
            let matcher: String?

            init(
                agentEvent: String,
                cmuxSubcommand: String,
                matcher: String? = nil,
                delivery: HookDelivery = .queued
            ) {
                self.agentEvent = agentEvent
                self.cmuxSubcommand = cmuxSubcommand
                self.matcher = matcher
                self.delivery = delivery
            }
        }

        enum HookDelivery: Equatable {
            case queued
            case direct
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
             dispatch: HookDispatch = .ambient,
             publishesStopNotification: Bool = true,
             sessionEndIsTurnBoundary: Bool = false,
             promptStartIsAuthoritative: Bool = false,
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
            self.dispatch = dispatch
            self.publishesStopNotification = publishesStopNotification
            self.sessionEndIsTurnBoundary = sessionEndIsTurnBoundary
            self.promptStartIsAuthoritative = promptStartIsAuthoritative
            self.aliases = Set(aliases.compactMap { alias in
                let normalized = alias.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                return normalized.isEmpty ? nil : normalized
            })
            self.feedHookEvents = feedHookEvents
            self.postInstallAction = postInstallAction
            self.postInstallNote = postInstallNote
        }
    }
}
