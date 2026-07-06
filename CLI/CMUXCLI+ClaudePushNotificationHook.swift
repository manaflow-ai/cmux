import Foundation

extension CMUXCLI {
    func runClaudePushNotificationHook(
        client: SocketClient,
        telemetry: CLISocketSentryTelemetry,
        parsedInput: ClaudeHookParsedInput,
        sessionStore: ClaudeHookSessionStore,
        workspaceArg: String?,
        surfaceArg: String?,
        hookSurfaceFlagIsExplicit: Bool,
        preferCallerTTYRouting: Bool,
        callerTTYBindingProvider: (() -> CallerTerminalBinding?)?,
        sendFeedTelemetry: (String?, String?) -> Void
    ) throws {
        telemetry.breadcrumb("claude-hook.push-notification")
        // PostToolUse bridge for Claude Code's PushNotification tool. The
        // tool delivers through a raw OSC desktop notification, and cmux
        // deliberately drops raw OSC notifications from surfaces running a
        // hook-integrated agent (they would duplicate hook notifications),
        // so without this bridge every PushNotification is silently
        // swallowed inside cmux. The tool's own Notification hook never
        // fires for it. Mirror the tool's delivery decision: bridge exactly
        // when the tool reports its terminal notification as sent
        // (tool_response.localSent); fail open when an older client omits
        // the structured response.
        guard let pushMessage = claudePushNotificationMessage(parsedInput.rawObject) else {
            telemetry.breadcrumb("claude-hook.push-notification.empty")
            print("OK")
            return
        }
        guard claudePushNotificationWasDelivered(parsedInput.rawObject) else {
            telemetry.breadcrumb("claude-hook.push-notification.skipped")
            print("OK")
            return
        }
        let mappedSession = parsedInput.sessionId.flatMap { try? sessionStore.lookup(sessionId: $0) }
        let workspaceId = try resolvePreferredWorkspaceIdForClaudeHook(
            preferred: mappedSession?.workspaceId,
            fallback: workspaceArg,
            preferCallerTTYOverFallback: preferCallerTTYRouting,
            callerTerminalBinding: callerTTYBindingProvider,
            client: client
        )
        let resolvedSurface = try resolvePreferredSurfaceForClaudeHookDetailed(
            preferred: mappedSession?.surfaceId,
            fallback: surfaceArg,
            fallbackIsExplicit: hookSurfaceFlagIsExplicit,
            workspaceId: workspaceId,
            callerTerminalBinding: callerTTYBindingProvider,
            client: client
        )
        let surfaceId = resolvedSurface.surfaceId
        sendFeedTelemetry(workspaceId, surfaceId)
        guard shouldApplyClaudeHookVisibleMutation(
            sessionStore: sessionStore,
            parsedInput: parsedInput,
            workspaceId: workspaceId,
            surfaceId: resolvedSurface.isAuthoritative ? surfaceId : nil,
            telemetry: telemetry
        ) else {
            telemetry.breadcrumb("claude-hook.push-notification.stale")
            print("OK")
            return
        }
        let claudePid = mappedSession?.pid ?? claudeAgentPID(from: ProcessInfo.processInfo.environment)
        guard !shouldSuppressNestedAgentVisibleMutations(
            currentAgentPID: claudePid,
            env: ProcessInfo.processInfo.environment
        ) else {
            telemetry.breadcrumb("claude-hook.push-notification.nested-suppressed")
            print("OK")
            return
        }
        let title = String(
            localized: "cli.claude-hook.notification.title",
            defaultValue: "Claude Code"
        )
        // A model-initiated push is an ungated always-deliver alert (no
        // meta tag, like legacy untagged payloads). No lifecycle/status
        // change: the agent is usually still running when it fires, and a
        // push must not flip a running pane to "Needs input".
        let payload = notificationPayload(title: title, subtitle: "", body: pushMessage)
        let response = try sendV1Command("notify_target_async \(workspaceId) \(surfaceId) \(payload)", client: client)
        print(response)
    }

    /// Message for a PushNotification PostToolUse payload: the tool input's
    /// `message`, falling back to the structured tool_response `message`.
    /// Read from rawObject: the compacted `object` allowlist does not keep
    /// `tool_input.message` or `tool_response`.
    private func claudePushNotificationMessage(_ object: [String: Any]?) -> String? {
        guard let object else { return nil }
        if let input = object["tool_input"] as? [String: Any],
           let message = firstString(in: input, keys: ["message"]) {
            return message
        }
        if let response = object["tool_response"] as? [String: Any],
           let message = firstString(in: response, keys: ["message"]) {
            return message
        }
        return nil
    }

    /// Whether the PushNotification tool actually delivered its terminal
    /// notification. tool_response is `{message, localSent?, disabledReason?,
    /// sentAt?}`: `localSent` is the terminal-channel outcome (the OSC path
    /// cmux suppresses for agent surfaces), and `disabledReason`
    /// (`config_off` | `user_present` | `no_transport`) explains a skip. A
    /// missing or unstructured response (older clients) fails open so the
    /// message is never silently dropped.
    private func claudePushNotificationWasDelivered(_ object: [String: Any]?) -> Bool {
        guard let response = object?["tool_response"] as? [String: Any] else { return true }
        if let localSent = response["localSent"] as? Bool {
            return localSent
        }
        return response["disabledReason"] == nil
    }
}
