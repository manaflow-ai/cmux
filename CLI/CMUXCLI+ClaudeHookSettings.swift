import Foundation

extension CMUXCLI {
    /// Emits the complete cmux-owned Claude settings object without contacting
    /// the app socket. Non-decision hooks only admit immutable events to the
    /// app-owned ordered queue; decision hooks remain direct and synchronous.
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
        try FileHandle.standardOutput.write(contentsOf: data)
    }

    private static func claudeQueuedHookGroup(
        matcher: String = "",
        subcommand: String
    ) -> [String: Any] {
        return claudeHookGroup(
            matcher: matcher,
            command: queuedAgentHookShellCommand(
                agent: "claude",
                subcommand: subcommand,
                disableEnvironmentVariable: "CMUX_CLAUDE_HOOKS_DISABLED"
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
