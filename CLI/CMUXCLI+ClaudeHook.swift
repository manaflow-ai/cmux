import Foundation
import CMUXAgentLaunch
import CmuxFoundation
import CmuxSocketControl
import CoreFoundation
import CryptoKit
import Darwin
#if canImport(LocalAuthentication)
import LocalAuthentication
#endif
#if canImport(Security)
import Security
#endif
#if canImport(Sentry)
import Sentry
#endif


// MARK: - Claude hook handler
extension CMUXCLI {
    func runClaudeHook(
        commandArgs: [String],
        client: SocketClient,
        telemetry: CLISocketSentryTelemetry,
        socketPassword: String? = nil
    ) throws {
        let subcommand = commandArgs.first?.lowercased() ?? "help"
        let hookArgs = Array(commandArgs.dropFirst())
        let hookWsFlag = optionValue(hookArgs, name: "--workspace")
        let workspaceArg = hookWsFlag ?? ProcessInfo.processInfo.environment["CMUX_WORKSPACE_ID"]
        let surfaceArg = optionValue(hookArgs, name: "--surface") ?? (hookWsFlag == nil ? ProcessInfo.processInfo.environment["CMUX_SURFACE_ID"] : nil)
        let rawInput = String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let parsedInput = parseClaudeHookInput(rawInput: rawInput)
        let sessionStore = ClaudeHookSessionStore()
        telemetry.breadcrumb(
            "claude-hook.input",
            data: [
                "subcommand": subcommand,
                "has_session_id": parsedInput.sessionId != nil,
                "has_workspace_flag": hookWsFlag != nil,
                "has_surface_flag": optionValue(hookArgs, name: "--surface") != nil
            ]
        )

        var didSendFeedTelemetry = false
        func sendClaudeFeedTelemetry(workspaceId: String? = nil) {
            didSendFeedTelemetry = true
            sendFeedTelemetry(
                client: client,
                source: "claude",
                subcommand: subcommand,
                parsedInput: parsedInput,
                workspaceId: workspaceId ?? workspaceArg,
                socketPassword: socketPassword
            )
        }
        defer {
            if !didSendFeedTelemetry {
                sendClaudeFeedTelemetry()
            }
        }

        switch subcommand {
        case "session-start", "active":
            telemetry.breadcrumb("claude-hook.session-start")
            let workspaceId = try resolvePreferredWorkspaceIdForClaudeHook(
                preferred: nil,
                fallback: workspaceArg,
                client: client
            )
            let surfaceId = try resolvePreferredSurfaceIdForClaudeHook(
                preferred: nil,
                fallback: surfaceArg,
                workspaceId: workspaceId,
                client: client
            )
            sendClaudeFeedTelemetry(workspaceId: workspaceId)
            let claudePid = claudeAgentPID(from: ProcessInfo.processInfo.environment)
            let suppressVisibleMutations = shouldSuppressNestedAgentVisibleMutations(
                currentAgentPID: claudePid,
                env: ProcessInfo.processInfo.environment
            )
            let launchCommand = agentLaunchCommandFromEnvironment(
                ProcessInfo.processInfo.environment,
                fallbackPID: claudePid,
                fallbackKind: "claude",
                cwd: parsedInput.cwd
            )
            let isClearSessionStart = isClaudeClearSessionStart(parsedInput)
            let canReplaceStoppedSession = shouldReplaceStoppedClaudeSession(
                sessionStore: sessionStore,
                parsedInput: parsedInput,
                workspaceId: workspaceId,
                telemetry: telemetry
            )
            let shouldPromoteActiveSession = isClearSessionStart || canReplaceStoppedSession
            if let sessionId = parsedInput.sessionId {
                // Non-clear SessionStart can arrive late from startup/resume/compact
                // after /clear, so only /clear or replacement of a stopped owner
                // establishes a new active boundary.
                try? sessionStore.upsert(
                    sessionId: sessionId,
                    workspaceId: workspaceId,
                    surfaceId: surfaceId,
                    cwd: parsedInput.cwd,
                    transcriptPath: parsedInput.transcriptPath,
                    pid: claudePid,
                    launchCommand: launchCommand,
                    isRestorable: false,
                    agentLifecycle: shouldPromoteActiveSession ? .running : .unknown,
                    markActive: shouldPromoteActiveSession,
                    turnId: parsedInput.turnId
                )
                if shouldPromoteActiveSession {
                    publishAgentSurfaceResumeBinding(
                        client: client,
                        workspaceId: workspaceId,
                        surfaceId: surfaceId,
                        kind: "claude",
                        displayName: String(localized: "cli.claude-hook.notification.title", defaultValue: "Claude Code"),
                        sessionId: sessionId,
                        cwd: parsedInput.cwd,
                        launchCommand: launchCommand
                    )
                }
            }
            // Register PID for stale-session detection and OSC suppression.
            // Startup/resume SessionStart remains non-visible; /clear is a
            // new active boundary and must keep the sidebar Running before
            // any late pre-clear Stop can write Idle.
            let shouldRegisterPID =
                shouldPromoteActiveSession ||
                shouldApplyClaudeHookVisibleMutation(
                    sessionStore: sessionStore,
                    parsedInput: parsedInput,
                    workspaceId: workspaceId,
                    telemetry: telemetry
                )
            if shouldRegisterPID, let claudePid, !suppressVisibleMutations {
                _ = try? sendV1Command(
                    "set_agent_pid \(Self.claudeCodeStatusKey) \(claudePid) --tab=\(workspaceId)\(socketPanelOption(surfaceId))",
                    client: client
                )
            }
            if isClearSessionStart, !suppressVisibleMutations {
                _ = try? sendV1Command("clear_notifications --tab=\(workspaceId)", client: client)
                setAgentLifecycle(
                    client: client,
                    key: Self.claudeCodeStatusKey,
                    lifecycle: .running,
                    workspaceId: workspaceId,
                    surfaceId: surfaceId
                )
                try setClaudeStatus(
                    client: client,
                    workspaceId: workspaceId,
                    surfaceId: surfaceId,
                    value: "Running",
                    icon: "bolt.fill",
                    color: "#4C8DFF",
                    pid: claudePid
                )
            }
            print("OK")

        case "stop", "idle":
            telemetry.breadcrumb("claude-hook.stop")
            do {
                // Turn ended. Don't consume session or clear PID — Claude is still alive.
                // Notification hook handles user-facing notifications; SessionEnd handles cleanup.
                let mappedSession = parsedInput.sessionId.flatMap { try? sessionStore.lookup(sessionId: $0) }
                let workspaceId = try resolvePreferredWorkspaceIdForClaudeHook(
                    preferred: mappedSession?.workspaceId,
                    fallback: workspaceArg,
                    client: client
                )
                let surfaceId = try resolvePreferredSurfaceIdForClaudeHook(
                    preferred: mappedSession?.surfaceId,
                    fallback: surfaceArg,
                    workspaceId: workspaceId,
                    client: client
                )
                let claudePid = mappedSession?.pid ?? claudeAgentPID(from: ProcessInfo.processInfo.environment)
                let suppressVisibleMutations = shouldSuppressNestedAgentVisibleMutations(
                    currentAgentPID: claudePid,
                    env: ProcessInfo.processInfo.environment
                )
                sendClaudeFeedTelemetry(workspaceId: workspaceId)

                guard shouldApplyClaudeHookVisibleMutation(
                    sessionStore: sessionStore,
                    parsedInput: parsedInput,
                    workspaceId: workspaceId,
                    telemetry: telemetry
                ) else {
                    telemetry.breadcrumb("claude-hook.stop.stale")
                    print("OK")
                    return
                }

                guard !suppressVisibleMutations else {
                    telemetry.breadcrumb("claude-hook.stop.nested-suppressed")
                    print("OK")
                    return
                }

                // Update session with transcript summary and send completion notification.
                let completion = summarizeClaudeHookStop(
                    parsedInput: parsedInput,
                    sessionRecord: mappedSession
                )
                if let sessionId = parsedInput.sessionId {
                    try? sessionStore.upsert(
                        sessionId: sessionId,
                        workspaceId: workspaceId,
                        surfaceId: surfaceId,
                        cwd: parsedInput.cwd,
                        transcriptPath: parsedInput.transcriptPath,
                        isRestorable: true,
                        agentLifecycle: .idle,
                        lastSubtitle: completion?.subtitle,
                        lastBody: completion?.body,
                        markActive: true,
                        allowsNewSessionReplacement: true
                    )
                    publishAgentSurfaceResumeBinding(
                        client: client,
                        workspaceId: workspaceId,
                        surfaceId: surfaceId,
                        kind: "claude",
                        displayName: String(localized: "cli.claude-hook.notification.title", defaultValue: "Claude Code"),
                        sessionId: sessionId,
                        cwd: parsedInput.cwd ?? mappedSession?.cwd,
                        launchCommand: mappedSession?.launchCommand
                    )
                }

                setAgentLifecycle(
                    client: client,
                    key: Self.claudeCodeStatusKey,
                    lifecycle: .idle,
                    workspaceId: workspaceId,
                    surfaceId: surfaceId
                )
                try? setClaudeStatus(
                    client: client,
                    workspaceId: workspaceId,
                    surfaceId: surfaceId,
                    value: "Idle",
                    icon: "pause.circle.fill",
                    color: "#8E8E93"
                )
                if let completion {
                    let title = String(
                        localized: "cli.claude-hook.notification.title",
                        defaultValue: "Claude Code"
                    )
                    let payload = notificationPayload(title: title, subtitle: completion.subtitle, body: completion.body)
                    _ = try? sendV1Command("notify_target_async \(workspaceId) \(surfaceId) \(payload)", client: client)
                }
                print("OK")
            } catch {
                if shouldIgnoreClaudeHookTeardownError(error) {
                    telemetry.breadcrumb("claude-hook.stop.ignored", data: ["error": String(describing: error)])
                    print("OK")
                    return
                }
                throw error
            }

        case "prompt-submit":
            telemetry.breadcrumb("claude-hook.prompt-submit")
            let mappedSession = parsedInput.sessionId.flatMap { try? sessionStore.lookup(sessionId: $0) }
            let workspaceId = try resolvePreferredWorkspaceIdForClaudeHook(
                preferred: mappedSession?.workspaceId,
                fallback: workspaceArg,
                client: client
            )
            let surfaceId = try resolvePreferredSurfaceIdForClaudeHook(
                preferred: mappedSession?.surfaceId,
                fallback: surfaceArg,
                workspaceId: workspaceId,
                client: client
            )
            let claudePid = mappedSession?.pid ?? claudeAgentPID(from: ProcessInfo.processInfo.environment)
            let suppressVisibleMutations = shouldSuppressNestedAgentVisibleMutations(
                currentAgentPID: claudePid,
                env: ProcessInfo.processInfo.environment
            )
            sendClaudeFeedTelemetry(workspaceId: workspaceId)
            let shouldApplyPromptSubmit =
                shouldApplyClaudeHookVisibleMutation(
                    sessionStore: sessionStore,
                    parsedInput: parsedInput,
                    workspaceId: workspaceId,
                    telemetry: telemetry
                ) ||
                shouldReplaceStoppedClaudeSession(
                    sessionStore: sessionStore,
                    parsedInput: parsedInput,
                    workspaceId: workspaceId,
                    telemetry: telemetry
                )
            guard shouldApplyPromptSubmit else {
                telemetry.breadcrumb("claude-hook.prompt-submit.stale")
                print("OK")
                return
            }
            guard !suppressVisibleMutations else {
                telemetry.breadcrumb("claude-hook.prompt-submit.nested-suppressed")
                print("OK")
                return
            }
            if let sessionId = parsedInput.sessionId {
                try? sessionStore.upsert(
                    sessionId: sessionId,
                    workspaceId: workspaceId,
                    surfaceId: surfaceId,
                    cwd: parsedInput.cwd,
                    transcriptPath: parsedInput.transcriptPath,
                    isRestorable: true,
                    agentLifecycle: .running,
                    markActive: true,
                    turnId: parsedInput.turnId
                )
                publishAgentSurfaceResumeBinding(
                    client: client,
                    workspaceId: workspaceId,
                    surfaceId: surfaceId,
                    kind: "claude",
                    displayName: String(localized: "cli.claude-hook.notification.title", defaultValue: "Claude Code"),
                    sessionId: sessionId,
                    cwd: parsedInput.cwd ?? mappedSession?.cwd,
                    launchCommand: mappedSession?.launchCommand
                )
            }
            _ = try sendV1Command("clear_notifications --tab=\(workspaceId)", client: client)
            setAgentLifecycle(
                client: client,
                key: Self.claudeCodeStatusKey,
                lifecycle: .running,
                workspaceId: workspaceId,
                surfaceId: surfaceId
            )
            try setClaudeStatus(
                client: client,
                workspaceId: workspaceId,
                surfaceId: surfaceId,
                value: "Running",
                icon: "bolt.fill",
                color: "#4C8DFF"
            )
            print("OK")

        case "notification", "notify":
            telemetry.breadcrumb("claude-hook.notification")
            var summary = summarizeClaudeHookNotification(parsedInput: parsedInput)

            let mappedSession = parsedInput.sessionId.flatMap { try? sessionStore.lookup(sessionId: $0) }
            let workspaceId = try resolvePreferredWorkspaceIdForClaudeHook(
                preferred: mappedSession?.workspaceId,
                fallback: workspaceArg,
                client: client
            )
            let claudePid = mappedSession?.pid ?? claudeAgentPID(from: ProcessInfo.processInfo.environment)
            let suppressVisibleMutations = shouldSuppressNestedAgentVisibleMutations(
                currentAgentPID: claudePid,
                env: ProcessInfo.processInfo.environment
            )
            sendClaudeFeedTelemetry(workspaceId: workspaceId)
            guard shouldApplyClaudeHookVisibleMutation(
                sessionStore: sessionStore,
                parsedInput: parsedInput,
                workspaceId: workspaceId,
                telemetry: telemetry
            ) else {
                telemetry.breadcrumb("claude-hook.notification.stale")
                print("OK")
                return
            }
            guard !suppressVisibleMutations else {
                telemetry.breadcrumb("claude-hook.notification.nested-suppressed")
                print("OK")
                return
            }
            if let mappedSession,
               let savedBody = mappedSession.lastBody, !savedBody.isEmpty,
               summary.body.contains("needs your attention") || summary.body.contains("needs your input") {
                summary = (subtitle: mappedSession.lastSubtitle ?? summary.subtitle, body: savedBody)
            }

            let surfaceId = try resolvePreferredSurfaceIdForClaudeHook(
                preferred: mappedSession?.surfaceId,
                fallback: surfaceArg,
                workspaceId: workspaceId,
                client: client
            )

            let title = String(
                localized: "cli.claude-hook.notification.title",
                defaultValue: "Claude Code"
            )
            let payload = notificationPayload(title: title, subtitle: summary.subtitle, body: summary.body)

            if let sessionId = parsedInput.sessionId {
                try? sessionStore.upsert(
                    sessionId: sessionId,
                    workspaceId: workspaceId,
                    surfaceId: surfaceId,
                    cwd: parsedInput.cwd,
                    transcriptPath: parsedInput.transcriptPath,
                    agentLifecycle: .needsInput,
                    lastSubtitle: summary.subtitle,
                    lastBody: summary.body
                )
            }

            setAgentLifecycle(
                client: client,
                key: Self.claudeCodeStatusKey,
                lifecycle: .needsInput,
                workspaceId: workspaceId,
                surfaceId: surfaceId
            )
            _ = try? setClaudeStatus(
                client: client,
                workspaceId: workspaceId,
                surfaceId: surfaceId,
                value: "Needs input",
                icon: "bell.fill",
                color: "#4C8DFF"
            )
            let response = try sendV1Command("notify_target_async \(workspaceId) \(surfaceId) \(payload)", client: client)
            print(response)

        case "session-end":
            telemetry.breadcrumb("claude-hook.session-end")
            // Final cleanup when Claude process exits.
            // Only clear when we are the primary cleanup path (Stop didn't fire first).
            // If Stop already consumed the session, consumedSession is nil and we skip
            // to avoid wiping the completion notification that Stop just delivered.
            let mappedSession = parsedInput.sessionId.flatMap { try? sessionStore.lookup(sessionId: $0) }
            let fallbackWorkspaceId = try? resolvePreferredWorkspaceIdForClaudeHook(
                preferred: mappedSession?.workspaceId,
                fallback: workspaceArg,
                client: client
            )
            let fallbackSurfaceId: String? = {
                guard let fallbackWorkspaceId else { return nil }
                return try? resolvePreferredSurfaceIdForClaudeHook(
                    preferred: mappedSession?.surfaceId,
                    fallback: surfaceArg,
                    workspaceId: fallbackWorkspaceId,
                    client: client
                )
            }()
            let consumedSession = try? sessionStore.consume(
                sessionId: parsedInput.sessionId,
                workspaceId: fallbackWorkspaceId,
                surfaceId: fallbackSurfaceId,
                turnId: parsedInput.turnId
            )
            // consume() calls clearActiveSessionIfMatching before returning
            // consumedSession, so isCurrent can treat consumedSession.sessionId
            // as current only when the consumed session was the active one.
            if let consumedSession {
                let workspaceId = consumedSession.workspaceId
                clearAgentSurfaceResumeBinding(
                    client: client,
                    workspaceId: workspaceId,
                    surfaceId: consumedSession.surfaceId,
                    sessionId: consumedSession.sessionId
                )
                sendClaudeFeedTelemetry(workspaceId: workspaceId)
                let shouldClearVisibleState = shouldApplyClaudeHookVisibleMutation(
                    sessionStore: sessionStore,
                    sessionId: consumedSession.sessionId,
                    turnId: parsedInput.turnId,
                    workspaceId: workspaceId,
                    telemetry: telemetry
                )
                let claudePid = consumedSession.pid ?? claudeAgentPID(from: ProcessInfo.processInfo.environment)
                let suppressVisibleMutations = shouldSuppressNestedAgentVisibleMutations(
                    currentAgentPID: claudePid,
                    env: ProcessInfo.processInfo.environment
                )
                if shouldClearVisibleState, !suppressVisibleMutations {
                    _ = try? sendV1Command(
                        "clear_agent_pid \(Self.claudeCodeStatusKey) --tab=\(workspaceId)\(socketPanelOption(consumedSession.surfaceId)) --clear-status",
                        client: client
                    )
                    try? sessionStore.clearAgentLifecycleIfPresent(
                        sessionId: consumedSession.sessionId,
                        workspaceId: workspaceId,
                        surfaceId: consumedSession.surfaceId
                    )
                    _ = try? sendV1Command("clear_notifications --tab=\(workspaceId)", client: client)
                } else {
                    telemetry.breadcrumb("claude-hook.session-end.stale")
                }
            }
            print("OK")

        case "cron-create-guard":
            telemetry.breadcrumb("claude-hook.cron-create-guard")
            let guardResponse = claudeCronCreateGuardResponse(parsedInput.rawObject)
            didSendFeedTelemetry = guardResponse == "{}"
            print(guardResponse)
            fflush(stdout)

        case "pre-tool-use":
            telemetry.breadcrumb("claude-hook.pre-tool-use")
            // Clears "Needs input" status and notification when Claude resumes work
            // (e.g. after permission grant). Runs async so it doesn't block tool execution.
            let mappedSession = parsedInput.sessionId.flatMap { try? sessionStore.lookup(sessionId: $0) }
            let workspaceId = try resolvePreferredWorkspaceIdForClaudeHook(
                preferred: mappedSession?.workspaceId,
                fallback: workspaceArg,
                client: client
            )
            let surfaceId = try resolvePreferredSurfaceIdForClaudeHook(
                preferred: mappedSession?.surfaceId,
                fallback: surfaceArg,
                workspaceId: workspaceId,
                client: client
            )
            sendClaudeFeedTelemetry(workspaceId: workspaceId)
            let claudePid = mappedSession?.pid ?? claudeAgentPID(from: ProcessInfo.processInfo.environment)
            let suppressVisibleMutations = shouldSuppressNestedAgentVisibleMutations(
                currentAgentPID: claudePid,
                env: ProcessInfo.processInfo.environment
            )
            guard shouldApplyClaudeHookVisibleMutation(
                sessionStore: sessionStore,
                parsedInput: parsedInput,
                workspaceId: workspaceId,
                telemetry: telemetry
            ) else {
                telemetry.breadcrumb("claude-hook.pre-tool-use.stale")
                print("OK")
                return
            }
            guard !suppressVisibleMutations else {
                telemetry.breadcrumb("claude-hook.pre-tool-use.nested-suppressed")
                print("OK")
                return
            }

            // AskUserQuestion means Claude is about to ask the user something.
            // Save question text in session so the Notification handler can use it
            // instead of the generic "Claude Code needs your attention".
            if let toolName = parsedInput.object?["tool_name"] as? String,
               toolName == "AskUserQuestion",
               let question = describeAskUserQuestion(parsedInput.object),
               let sessionId = parsedInput.sessionId {
                // Preserve a non-empty surfaceId from SessionStart; passing ""
                // would overwrite it and cause notifications to target the wrong workspace.
                let existingSurfaceId = nonEmptyClaudeHookIdentifier(mappedSession?.surfaceId) ?? surfaceId
                try? sessionStore.upsert(
                    sessionId: sessionId,
                    workspaceId: workspaceId,
                    surfaceId: existingSurfaceId,
                    cwd: parsedInput.cwd,
                    transcriptPath: parsedInput.transcriptPath,
                    agentLifecycle: .needsInput,
                    lastSubtitle: "Waiting",
                    lastBody: question
                )
                setAgentLifecycle(
                    client: client,
                    key: Self.claudeCodeStatusKey,
                    lifecycle: .needsInput,
                    workspaceId: workspaceId,
                    surfaceId: existingSurfaceId
                )
                // Don't clear notifications or set status here.
                // The Notification hook fires right after and will use the saved question.
                print("OK")
                return
            }

            if let sessionId = parsedInput.sessionId {
                try? sessionStore.upsert(
                    sessionId: sessionId,
                    workspaceId: workspaceId,
                    surfaceId: surfaceId,
                    cwd: parsedInput.cwd,
                    transcriptPath: parsedInput.transcriptPath,
                    agentLifecycle: .running
                )
            }
            _ = try? sendV1Command("clear_notifications --tab=\(workspaceId)", client: client)
            setAgentLifecycle(
                client: client,
                key: Self.claudeCodeStatusKey,
                lifecycle: .running,
                workspaceId: workspaceId,
                surfaceId: surfaceId
            )

            let statusValue: String
            if UserDefaults.standard.bool(forKey: "claudeCodeVerboseStatus"),
               let toolStatus = describeToolUse(parsedInput.object) {
                statusValue = toolStatus
            } else {
                statusValue = "Running"
            }
            try setClaudeStatus(
                client: client,
                workspaceId: workspaceId,
                surfaceId: surfaceId,
                value: statusValue,
                icon: "bolt.fill",
                color: "#4C8DFF",
                pid: claudePid
            )
            print("OK")

        case "help", "--help", "-h":
            telemetry.breadcrumb("claude-hook.help")
            print(
                """
                cmux claude-hook <session-start|stop|session-end|notification|prompt-submit|pre-tool-use> [--workspace <id|index>] [--surface <id|index>]
                """
            )

        default:
            throw CLIError(message: "Unknown claude-hook subcommand: \(subcommand)")
        }
    }

}
