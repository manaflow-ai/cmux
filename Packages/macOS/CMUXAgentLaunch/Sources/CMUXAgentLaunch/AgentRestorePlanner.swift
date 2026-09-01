import Foundation

/// Builds shell-free restore invocations from structured persisted records.
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

    /// Creates a restore planner.
    ///
    /// - Parameter isExecutableFile: Executable-path lookup used for optional wrapper shims.
    public init(isExecutableFile: @escaping @Sendable (String) -> Bool) {
        self.isExecutableFile = isExecutableFile
    }

    /// Creates a restore planner backed by an injected executable-file resolver.
    ///
    /// - Parameter executableFileResolver: The filesystem dependency used to resolve wrapper shims.
    public init(executableFileResolver: AgentRestoreExecutableFileResolver) {
        self.init(isExecutableFile: executableFileResolver.isExecutableFile(atPath:))
    }

    /// Produces the final direct process invocation for a persisted restore request.
    ///
    /// - Parameters:
    ///   - request: Structured restore data.
    ///   - ambientEnvironment: The current CLI environment inherited by the child.
    /// - Returns: A direct invocation, or `nil` when the record cannot be restored safely.
    public func invocation(
        for request: AgentRestoreRequest,
        ambientEnvironment: [String: String]
    ) -> AgentRestoreInvocation? {
        let kind = normalizedKind(request.kind)
        guard let plannedArguments = plannedArguments(for: request, kind: kind),
              !plannedArguments.values.isEmpty else {
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
        if AgentRestoreRouteClassifier().route(for: request) != .direct {
            if kind == "codex" {
                environment.removeValue(forKey: "CODEX_HOME")
            } else if kind == "claude" {
                for key in Self.claudeAuthSelectionEnvironmentKeys {
                    environment.removeValue(forKey: key)
                }
            }
        }
        let restoredEnvironment = restoredEnvironment(for: request, kind: kind)
        environment.merge(restoredEnvironment) { _, restored in restored }

        var routedArguments = sanitizedArguments
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

    private func plannedArguments(
        for request: AgentRestoreRequest,
        kind: String
    ) -> (values: [String], removesCapturedWorkingDirectoryOptions: Bool)? {
        let preparedArguments = request.preparedArguments.flatMap {
            $0.isEmpty ? nil : $0
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
        }
    }

    private func restoredEnvironment(
        for request: AgentRestoreRequest,
        kind: String
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
              ),
              (first as NSString).lastPathComponent == restoreLaunch.executableName else {
            return arguments
        }

        if first != restoreLaunch.executableName {
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
