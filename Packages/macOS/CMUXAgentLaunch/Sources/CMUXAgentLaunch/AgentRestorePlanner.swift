import Foundation

/// Builds shell-free restore and fork invocations from structured persisted records.
public struct AgentRestorePlanner: Sendable {
    private static let claudeAuthSelectionEnvironmentKeys: Set<String> = [
        "ANTHROPIC_API_KEY",
        "ANTHROPIC_AUTH_TOKEN",
        "ANTHROPIC_BASE_URL",
        "ANTHROPIC_MODEL",
        "ANTHROPIC_SMALL_FAST_MODEL",
        "CLAUDE_CODE_USE_BEDROCK",
        "CLAUDE_CODE_USE_VERTEX",
        "CLAUDE_CONFIG_DIR",
    ]

    private let isExecutableFile: @Sendable (String) -> Bool
    private let isReadableFile: @Sendable (String) -> Bool

    /// Creates a restore planner.
    ///
    /// - Parameters:
    ///   - isExecutableFile: Executable-path lookup used for optional wrapper shims.
    ///   - isReadableFile: Readable-file lookup used to drop captured file-valued
    ///     options (Claude `--settings <path>`) whose file no longer exists.
    ///     Defaults to the live filesystem.
    public init(
        isExecutableFile: @escaping @Sendable (String) -> Bool,
        isReadableFile: @escaping @Sendable (String) -> Bool = AgentRestoreReadableFileResolver().isReadableFile(atPath:)
    ) {
        self.isExecutableFile = isExecutableFile
        self.isReadableFile = isReadableFile
    }

    /// Creates a restore planner backed by injected filesystem resolvers.
    ///
    /// - Parameters:
    ///   - executableFileResolver: The filesystem dependency used to resolve wrapper shims.
    ///   - readableFileResolver: The filesystem dependency used to validate captured
    ///     file-valued options at plan time. Defaults to the live filesystem.
    public init(
        executableFileResolver: AgentRestoreExecutableFileResolver,
        readableFileResolver: AgentRestoreReadableFileResolver = AgentRestoreReadableFileResolver()
    ) {
        self.init(
            isExecutableFile: executableFileResolver.isExecutableFile(atPath:),
            isReadableFile: readableFileResolver.isReadableFile(atPath:)
        )
    }

    /// Produces the final direct process invocation for a persisted restore or fork request.
    ///
    /// - Parameters:
    ///   - request: Structured restore or fork data.
    ///   - ambientEnvironment: The current CLI environment inherited by the child.
    /// - Returns: A direct invocation, or `nil` when the record cannot be restored safely.
    public func invocation(
        for request: AgentRestoreRequest,
        ambientEnvironment: [String: String]
    ) -> AgentRestoreInvocation? {
        let kind = normalizedKind(request.kind)
        let routedClaudeResume = routedClaudeResumeArguments(
            for: request,
            kind: kind,
            ambientEnvironment: ambientEnvironment
        )
        guard let plannedArguments = plannedArguments(
            for: request,
            kind: kind,
            routedClaudeResume: routedClaudeResume
        ), !plannedArguments.values.isEmpty else {
            return nil
        }

        let workingDirectory = normalized(
            request.workingDirectory ?? request.launchCommand?.workingDirectory
        )
        let sanitizedArguments: [String]
        if plannedArguments.removesCapturedWorkingDirectoryOptions {
            let workingDirectories = [
                workingDirectory,
                normalized(request.launchCommand?.workingDirectory),
            ].compactMap { $0 }
            sanitizedArguments = workingDirectories.reduce(plannedArguments.values) {
                AgentLaunchSanitizer.removingSavedWorkingDirectoryOptions(
                    from: $0,
                    workingDirectory: $1
                )
            }
        } else {
            sanitizedArguments = retargetPreparedWorkingDirectory(
                in: plannedArguments.values,
                request: request,
                workingDirectory: workingDirectory
            )
        }
        guard !sanitizedArguments.isEmpty else { return nil }

        var environment = ambientEnvironment
        let restoredEnvironment = restoredEnvironment(
            for: request,
            kind: kind,
            routedThroughSubrouter: routedClaudeResume != nil
        )
        environment.merge(restoredEnvironment) { _, restored in restored }
        if routedClaudeResume != nil {
            // Subrouter recomputes the Claude auth selection from the live pool
            // and re-exports its own markers; nothing captured or inherited may
            // pin the restored session to launch-time routing.
            for key in SubrouterClaudeResumeRouting.restoreOwnedEnvironmentKeys {
                environment.removeValue(forKey: key)
            }
        }

        var routedArguments = sanitizedArguments
        if kind == "claude", request.mode != .direct {
            // A captured --settings path is checked here, not at capture: the file
            // existed then, and only the restoring machine knows whether it still
            // does. Claude refuses to start on a missing settings file.
            routedArguments = ClaudeRestoreSettingsPathFilter(isReadableFile: isReadableFile)
                .removingUnreadableSettingsPaths(from: routedArguments)
            guard !routedArguments.isEmpty else { return nil }
        }
        let hermesProfilePin: HermesAgentResumeProfilePin?
        if kind == "hermes-agent", request.mode != .direct {
            let pin = HermesAgentResumeProfilePin(
                hermesHome: restoredEnvironment["HERMES_HOME"],
                homeDirectory: normalized(ambientEnvironment["HOME"]) ?? NSHomeDirectory()
            )
            environment["HERMES_HOME"] = pin.hermesHome
            routedArguments = pin.applying(to: routedArguments)
            hermesProfilePin = pin
        } else {
            hermesProfilePin = nil
        }
        if request.mode != .direct {
            routedArguments = routeManagedWrapper(
                arguments: routedArguments,
                request: request,
                kind: kind,
                environment: &environment
            )
        }
        guard !routedArguments.isEmpty else { return nil }

        let preflights = hermesPreflights(
            arguments: &routedArguments,
            kind: kind,
            environment: environment,
            ambientEnvironment: ambientEnvironment,
            profilePin: hermesProfilePin
        )
        return AgentRestoreInvocation(
            arguments: routedArguments,
            workingDirectory: workingDirectory,
            environment: environment,
            preflightInvocations: preflights
        )
    }

    /// Returns the `sr claude proxy --resume <id>` argv for a resume whose launch
    /// record proves it went through Subrouter and whose launcher is reachable on
    /// the restore PATH, or `nil` to keep the ordinary claude replay.
    ///
    /// Provenance never looks at the captured `ANTHROPIC_BASE_URL`; the local
    /// pool at `http://127.0.0.1:31415` is proven exactly like a hosted one, by
    /// the launcher marker and the wrapper's launch-bound copy agreeing.
    private func routedClaudeResumeArguments(
        for request: AgentRestoreRequest,
        kind: String,
        ambientEnvironment: [String: String]
    ) -> [String]? {
        guard kind == "claude",
              request.mode == .resumeAgent,
              let checkpointID = normalized(request.checkpointID),
              let launch = request.launchCommand else {
            return nil
        }
        let router = SubrouterClaudeResumeRouting()
        guard let routed = router.resumeArguments(
            launcher: launch.launcher,
            sessionID: checkpointID,
            launchArguments: launch.arguments,
            environment: launch.environment
        ), let launcherExecutable = routed.first,
        isResolvableOnRestorePath(launcherExecutable, ambientEnvironment: ambientEnvironment) else {
            // Without the launcher the routed command could never start; the
            // captured replay still launches and is what shipped before.
            return nil
        }
        return AgentResumeArgv.claudeArgvApplyingObservedPermissionMode(
            routed,
            observedPermissionMode: request.observedPermissionMode
        )
    }

    /// Mirrors the CLI's restore executable lookup: a bare name resolves only
    /// through the ambient `PATH`, and an empty component never means `.`.
    private func isResolvableOnRestorePath(
        _ executable: String,
        ambientEnvironment: [String: String]
    ) -> Bool {
        guard !executable.isEmpty else { return false }
        if executable.contains("/") {
            return isExecutableFile(executable)
        }
        let path = ambientEnvironment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        return path.split(separator: ":").contains { directory in
            !directory.isEmpty
                && isExecutableFile(
                    URL(fileURLWithPath: String(directory), isDirectory: true)
                        .appendingPathComponent(executable, isDirectory: false)
                        .path
                )
        }
    }

    private func plannedArguments(
        for request: AgentRestoreRequest,
        kind: String,
        routedClaudeResume: [String]?
    ) -> (values: [String], removesCapturedWorkingDirectoryOptions: Bool)? {
        let preparedArguments = request.preparedArguments.flatMap {
            $0.isEmpty ? nil : $0
        }
        if let routedClaudeResume, request.mode == .resumeAgent {
            return (routedClaudeResume, true)
        }
        switch request.mode {
        case .direct:
            return (preparedArguments ?? request.launchCommand?.arguments).map {
                ($0, false)
            }
        case .relaunchAgent:
            if let preparedArguments {
                return (preparedArguments, false)
            }
            guard let launchCommand = request.launchCommand else { return nil }
            return AgentResumeArgv().builtInRelaunchKind(
                kind: kind,
                executablePath: launchCommand.executablePath,
                arguments: launchCommand.arguments
            ).map { ($0, true) }
        case .resumeAgent:
            guard let checkpointID = normalized(request.checkpointID) else { return nil }
            let launch = request.launchCommand
            switch AgentResumeArgv().launcherResolution(
                launcher: launch?.launcher,
                sessionId: checkpointID,
                executablePath: launch?.executablePath,
                arguments: launch?.arguments ?? []
            ) {
            case .resolved(let arguments):
                if let arguments {
                    return (arguments, true)
                }
                return preparedArguments.map { ($0, false) }
            case .passthrough:
                if let arguments = AgentResumeArgv().builtInKind(
                    kind: kind,
                    sessionId: checkpointID,
                    executablePath: launch?.executablePath,
                    arguments: launch?.arguments ?? [],
                    observedPermissionMode: request.observedPermissionMode
                ) {
                    return (arguments, true)
                }
                return preparedArguments.map { ($0, false) }
            }
        case .forkAgent:
            if let preparedArguments {
                return (preparedArguments, false)
            }
            guard let checkpointID = normalized(request.checkpointID) else { return nil }
            let launch = request.launchCommand
            switch AgentForkArgv().launcherResolution(
                launcher: launch?.launcher,
                sessionId: checkpointID,
                executablePath: launch?.executablePath,
                arguments: launch?.arguments ?? []
            ) {
            case .resolved(let arguments):
                return arguments.map { ($0, true) }
            case .passthrough:
                return AgentForkArgv().builtInKind(
                    kind: kind,
                    sessionId: checkpointID,
                    executablePath: launch?.executablePath,
                    arguments: launch?.arguments ?? [],
                    observedPermissionMode: request.observedPermissionMode
                ).map { ($0, true) }
            }
        }
    }

    private func restoredEnvironment(
        for request: AgentRestoreRequest,
        kind: String,
        routedThroughSubrouter: Bool
    ) -> [String: String] {
        var captured = request.launchCommand?.environment ?? [:]
        captured.merge(request.environment) { _, binding in binding }
        if kind == "codex",
           let rawCodexHome = normalized(captured["CODEX_HOME"]),
           let launchWorkingDirectory = normalized(request.launchCommand?.workingDirectory)
               ?? normalized(request.workingDirectory) {
            // CODEX_HOME is interpreted relative to the process cwd. Preserve
            // the launch-time meaning when a restored surface uses a different
            // cwd (for example, after a worktree rotation).
            captured["CODEX_HOME"] = CodexHomeResolver().resolve(
                launchEnvironment: ["CODEX_HOME": rawCodexHome],
                launchWorkingDirectory: launchWorkingDirectory,
                launchVerificationHome: request.launchCommand?.verificationHome,
                fallbackHomeDirectory: launchWorkingDirectory
            )
        }
        if request.mode == .direct {
            return captured
        }
        var selected = AgentLaunchEnvironmentPolicy().selectedRestoreEnvironment(
            from: captured,
            kind: kind
        )
        if kind == "claude" {
            if routedThroughSubrouter {
                // The launcher owns auth selection for a routed resume.
                for key in SubrouterClaudeResumeRouting.restoreOwnedEnvironmentKeys {
                    selected.removeValue(forKey: key)
                }
                return selected
            }
            // The markers are restore-record evidence, not a child environment:
            // a plain replay must not advertise a launcher that did not start it.
            selected.removeValue(forKey: SubrouterClaudeResumeRouting.environmentKey)
            selected.removeValue(forKey: SubrouterClaudeResumeRouting.launchBoundEnvironmentKey)
            let keys = selected.keys.sorted().filter {
                Self.claudeAuthSelectionEnvironmentKeys.contains($0)
            }
            if !keys.isEmpty {
                selected["CMUX_PRESERVE_CLAUDE_AUTH_SELECTION_ENV"] = "1"
                selected["CMUX_PRESERVE_CLAUDE_AUTH_SELECTION_ENV_KEYS"] = keys.joined(separator: ",")
            }
        }
        return selected
    }

    private func retargetPreparedWorkingDirectory(
        in arguments: [String],
        request: AgentRestoreRequest,
        workingDirectory: String?
    ) -> [String] {
        guard request.mode != .direct,
              let capturedWorkingDirectory = normalized(
                  request.preparedArgumentsWorkingDirectory
                      ?? request.launchCommand?.workingDirectory
              ),
              let workingDirectory,
              capturedWorkingDirectory != workingDirectory else {
            return arguments
        }
        return arguments.map { argument in
            if argument == capturedWorkingDirectory {
                return workingDirectory
            }
            let assignmentSuffix = "=\(capturedWorkingDirectory)"
            guard argument.hasSuffix(assignmentSuffix) else {
                return argument
            }
            return String(argument.dropLast(assignmentSuffix.count))
                + "=\(workingDirectory)"
        }
    }

    private func routeManagedWrapper(
        arguments: [String],
        request: AgentRestoreRequest,
        kind: String,
        environment: inout [String: String]
    ) -> [String] {
        guard let first = arguments.first,
              let restoreLaunch = AgentRestoreLaunch(
                  kind: kind,
                  sessionID: request.checkpointID
              ) else {
            return arguments
        }

        if kind == "claude",
           let checkpointID = normalized(request.checkpointID),
           let routedPrefix = SubrouterClaudeResumeRouting().resumeArguments(
               launcher: request.launchCommand?.launcher,
               sessionID: checkpointID,
               launchArguments: request.launchCommand?.arguments ?? [],
               environment: request.launchCommand?.environment
           ),
           arguments.starts(with: routedPrefix.prefix(5)) {
            // `sr` resolves `claude` through PATH, where the per-surface shim
            // still routes into cmux-claude-wrapper. The wrapper must recognise
            // this as an app-owned restore and keep launching the captured
            // Claude binary; the launcher itself is not wrapped.
            environment.merge(AgentResumeArgv().managedWrapperCustomExecutableEnvironment(
                kind: kind,
                executablePath: request.launchCommand?.executablePath,
                arguments: request.launchCommand?.arguments ?? []
            )) { _, captured in captured }
            environment["CMUX_AGENT_RESTORE_LAUNCH"] = restoreLaunch.authorizationEnvironmentValue
            return arguments
        }

        guard (first as NSString).lastPathComponent == restoreLaunch.executableName else {
            return arguments
        }

        environment.merge(AgentResumeArgv().managedWrapperCustomExecutableEnvironment(
            kind: kind,
            executablePath: request.launchCommand?.executablePath,
            arguments: request.launchCommand?.arguments ?? []
        )) { _, captured in captured }
        if first != restoreLaunch.executableName,
           (first as NSString).lastPathComponent == restoreLaunch.executableName {
            environment[restoreLaunch.customExecutablePathEnvironmentKey] = first
        }
        environment["CMUX_AGENT_RESTORE_LAUNCH"] = restoreLaunch.authorizationEnvironmentValue
        let routedExecutable =
            normalized(environment[restoreLaunch.wrapperShimEnvironmentKey])
                .flatMap { isExecutableFile($0) ? $0 : nil }
            ?? (first.contains("/") && isExecutableFile(first) ? first : nil)
            ?? restoreLaunch.executableName
        return [routedExecutable] + Array(arguments.dropFirst())
    }

    private func hermesPreflights(
        arguments: inout [String],
        kind: String,
        environment: [String: String],
        ambientEnvironment: [String: String],
        profilePin: HermesAgentResumeProfilePin?
    ) -> [AgentRestorePreflightInvocation] {
        guard kind == "hermes-agent" else { return [] }
        arguments = HermesAgentCodexEnvironment.argumentsByReplacingOpenAICodexProvider(arguments)
        guard !arguments.contains(where: { $0.contains("model.api_mode") }),
              hermesProvider(in: arguments).map({
                  $0 == HermesAgentCodexEnvironment.defaultProvider || $0 == "openai-codex"
              }) ?? true else {
            return []
        }
        let resolvedEnvironment = HermesAgentCodexEnvironment.applyingDefaultCodexBaseURL(
            to: environment,
            ambientEnvironment: ambientEnvironment
        )
        guard let baseURL = normalized(
            resolvedEnvironment[HermesAgentCodexEnvironment.customBaseURLEnvironmentKey]
        ), let executable = arguments.first else {
            return []
        }
        var settings = [
            ("model.provider", HermesAgentCodexEnvironment.defaultProvider),
            ("model.base_url", baseURL),
            ("model.api_mode", HermesAgentCodexEnvironment.codexResponsesAPIMode),
        ]
        if let model = HermesAgentCodexEnvironment.defaultCodexModel(
            environment: resolvedEnvironment,
            ambientEnvironment: ambientEnvironment
        ) {
            settings.append(("model.default", model))
        }
        let commandPrefix = [executable] + (profilePin?.profileArguments(in: arguments) ?? [])
        return settings.compactMap { key, value in
            AgentRestorePreflightInvocation(
                arguments: commandPrefix + ["config", "set", key, value],
                environment: resolvedEnvironment
            )
        }
    }

    private func hermesProvider(in arguments: [String]) -> String? {
        var index = arguments.startIndex
        while index < arguments.endIndex {
            let argument = arguments[index]
            if argument == "--provider", arguments.indices.contains(index + 1) {
                return arguments[index + 1]
            }
            if argument.hasPrefix("--provider=") {
                return String(argument.dropFirst("--provider=".count))
            }
            index += 1
        }
        return nil
    }

    private func normalized(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    private func normalizedKind(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
