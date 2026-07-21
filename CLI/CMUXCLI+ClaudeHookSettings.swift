import Foundation

extension CMUXCLI {
    private static let claudeLifecycleHookTimeoutSeconds = 5

    /// Emits the complete cmux-owned Claude settings object without contacting
    /// the app socket. Non-decision lifecycle hooks use the same bounded
    /// fire-and-forget admission path as other installed agent integrations.
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
            let deliveryCommand = "\(hookCLI) hooks claude \(definition.subcommand)"
            hooks[definition.event, default: []].append(Self.claudeDeferredHookGroup(
                matcher: definition.matcher,
                deliveryCommand: deliveryCommand
            ))
        }

        hooks["Stop", default: []].append(contentsOf: [
            Self.claudeDeferredHookGroup(
                deliveryCommand: "\(hookCLI) hooks feed --source claude"
            ),
            Self.claudeHookGroup(
                command: "\(hookCLI) hooks claude auto-name",
                timeout: 120,
                isAsync: true
            ),
        ])
        hooks["SubagentStop"] = [
            Self.claudeDeferredHookGroup(
                deliveryCommand: "\(hookCLI) hooks feed --source claude"
            ),
        ]
        hooks["PreToolUse"] = [
            Self.claudeHookGroup(
                matcher: "CronCreate",
                command: "\(hookCLI) hooks claude cron-create-guard",
                timeout: 5
            ),
            Self.claudeDeferredHookGroup(
                deliveryCommand: "\(hookCLI) hooks claude pre-tool-use"
            ),
        ]
        hooks["PostToolUse"] = [
            Self.claudeDeferredHookGroup(
                matcher: "PushNotification",
                deliveryCommand: "\(hookCLI) hooks claude push-notification"
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

    private static func claudeDeferredHookGroup(
        matcher: String = "",
        deliveryCommand: String
    ) -> [String: Any] {
        claudeHookGroup(
            matcher: matcher,
            command: boundedFireAndForgetHookShellCommand(
                deliveryArgumentSetup: "set -- \(deliveryCommand)",
                agentName: "claude",
                pidEnvironmentVariable: "CMUX_CLAUDE_PID"
            ),
            timeout: claudeLifecycleHookTimeoutSeconds
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
