import Foundation
import CMUXAgentLaunch

extension CMUXCLI {
    /// Emits the complete cmux-owned Claude settings object without contacting
    /// the app socket. Non-decision hooks only admit immutable events to the
    /// app-owned ordered queue, through the session's hook spool when the
    /// wrapper started a forwarder; decision hooks remain direct and synchronous.
    func emitClaudeWrapperInjectSettings() throws {
        let hookCLI = #""${CMUX_CLAUDE_HOOK_CMUX_BIN:-cmux}""#
        let lifecycleDefinitions: [(
            event: String,
            matcher: String,
            subcommand: String
        )] = [
            ("SessionStart", "", "session-start"),
            ("Stop", "", "stop"),
            ("SessionEnd", "", "session-end"),
            ("Notification", "", "notification"),
            ("UserPromptSubmit", "", "prompt-submit"),
        ]

        var hooks: [String: [[String: Any]]] = [:]
        for definition in lifecycleDefinitions {
            hooks[definition.event, default: []].append(Self.claudeQueuedHookGroup(
                matcher: definition.matcher,
                subcommand: definition.subcommand
            ))
        }

        hooks["Stop", default: []].append(contentsOf: [
            Self.claudeQueuedHookGroup(
                subcommand: "feed"
            ),
            Self.claudeHookGroup(
                command: "\(hookCLI) hooks claude auto-name",
                timeout: 120,
                isAsync: true
            ),
        ])
        hooks["SubagentStop"] = [
            Self.claudeQueuedHookGroup(
                subcommand: "feed"
            ),
        ]
        hooks["PreToolUse"] = [
            Self.claudeHookGroup(
                matcher: "CronCreate",
                command: "\(hookCLI) hooks claude cron-create-guard",
                timeout: 5
            ),
            Self.claudeQueuedHookGroup(
                subcommand: "pre-tool-use"
            ),
        ]
        hooks["PostToolUse"] = [
            Self.claudeQueuedHookGroup(
                matcher: "PushNotification",
                subcommand: "push-notification"
            ),
        ]
        hooks["PermissionRequest"] = [
            Self.claudeHookGroup(
                command: "\(hookCLI) hooks feed --source claude",
                timeout: 125
            ),
        ]

        let settings: [String: Any] = [
            "preferredNotifChannel": "notifications_disabled",
            "hooks": hooks,
        ]
        let data = try JSONSerialization.data(
            withJSONObject: settings,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        cliWriteStdout(data)
    }

    private static func claudeQueuedHookGroup(
        matcher: String = "",
        subcommand: String
    ) -> [String: Any] {
        // Wrapped sessions publish to their spool with shell builtins; the
        // CLI admission command is the fallback outside a live forwarder.
        let producer = AgentHookSpoolProducer(agent: "claude")
        return claudeHookGroup(
            matcher: matcher,
            command: producer.command(
                subcommand: subcommand,
                fallback: queuedAgentHookShellCommand(
                    agent: "claude",
                    subcommand: subcommand,
                    disableEnvironmentVariable: producer.disableEnvironmentKey
                )
            ),
            timeout: agentHookDeclaredTimeoutSeconds
        )
    }

    private static func claudeHookGroup(
        matcher: String = "",
        command: String,
        timeout: Int,
        isAsync: Bool = false
    ) -> [String: Any] {
        var hook: [String: Any] = [
            "type": "command",
            "command": command,
            "timeout": timeout,
        ]
        if isAsync {
            hook["async"] = true
        }
        return [
            "matcher": matcher,
            "hooks": [hook],
        ]
    }
}
