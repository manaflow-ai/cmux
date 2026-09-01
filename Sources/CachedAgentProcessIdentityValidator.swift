import CMUXAgentLaunch
import Foundation

struct CachedAgentProcessIdentityValidator: Sendable {
    enum HermesSessionValidation: Sendable {
        /// A cached snapshot can outlive a conversation switch in the same process.
        case cachedSnapshot

        /// The current hook-store record was loaded alongside the process observation.
        case currentHookRecord
    }

    func currentProcess(
        _ process: CmuxTopProcessArguments,
        matches snapshot: SessionRestorableAgentSnapshot,
        hermesSessionValidation: HermesSessionValidation = .cachedSnapshot
    ) -> Bool {
        if let liveKind = normalizedProcessValue(process.environment["CMUX_AGENT_LAUNCH_KIND"]),
           !Self.launchKind(liveKind, matches: snapshot.kind, launcher: snapshot.launchCommand?.launcher) {
            return false
        }
        if snapshot.kind == .hermesAgent {
            let observed = VaultObservedAgentProcess(
                processName: process.arguments.first.map(Self.executableBasename) ?? "",
                processPath: process.arguments.first,
                arguments: process.arguments,
                environment: process.environment
            )
            guard CmuxVaultAgentRegistration.builtInHermes.detect.matches(observed),
                  observed.isInteractiveHermesAgentInvocation else {
                return false
            }
            guard let explicitSessionID = CmuxVaultAgentPersistedSessionStore.hermesStateDB
                .explicitSessionID(arguments: process.arguments) else {
                // A fresh hook record supplies the missing session identity. A
                // cached snapshot cannot: Hermes can switch conversations without
                // changing its PID or bare argv.
                return hermesSessionValidation == .currentHookRecord
            }
            return ManagedAgentSessionIdentity.sessionIDsMatch(
                kind: snapshot.kind.rawValue,
                lhs: explicitSessionID,
                rhs: snapshot.sessionId
            )
        }
        guard currentProcessExecutable(process.arguments, environment: process.environment, matches: snapshot) else {
            return false
        }
        return currentProcessSession(process.arguments, matches: snapshot)
    }

    private func currentProcessExecutable(
        _ arguments: [String],
        environment: [String: String],
        matches snapshot: SessionRestorableAgentSnapshot
    ) -> Bool {
        guard let liveExecutable = arguments.first.map(executableBasename) else { return false }
        if let liveKind = normalizedProcessValue(environment["CMUX_AGENT_LAUNCH_KIND"]),
           Self.launchKind(liveKind, matches: snapshot.kind, launcher: snapshot.launchCommand?.launcher),
           normalizedProcessValue(snapshot.launchCommand?.launcher)?.compare(liveKind, options: [.caseInsensitive, .literal]) == .orderedSame,
           liveProcessExecutableMatchesRecordedAgent(
               kind: snapshot.kind,
               liveExecutable: liveExecutable,
               recordedExecutable: snapshot.kind.rawValue,
               arguments: arguments,
               environment: [:]
           ) {
            return true
        }
        if let recordedExecutable = recordedExecutableBasename(snapshot),
           liveProcessExecutableMatchesRecordedAgent(
               kind: snapshot.kind,
               liveExecutable: liveExecutable,
               recordedExecutable: recordedExecutable,
               arguments: arguments,
               environment: environment
           ) {
            return true
        }
        guard let registration = snapshot.registration else {
            return liveProcessExecutableMatchesRecordedAgent(
                kind: snapshot.kind,
                liveExecutable: liveExecutable,
                recordedExecutable: snapshot.kind.rawValue,
                arguments: arguments,
                environment: environment
            )
        }
        return registrationDetectRule(registration.detect, matchesExecutable: liveExecutable, arguments: arguments)
    }

    private func currentProcessSession(
        _ arguments: [String],
        matches snapshot: SessionRestorableAgentSnapshot
    ) -> Bool {
        if let registration = snapshot.registration {
            let observedSessionID: String?
            switch registration.sessionIdSource {
            case .argvOption(let option):
                guard let observedSessionID = nonOptionValue(after: option, in: arguments) else {
                    // An argv-keyed registration cannot prove ownership when
                    // its identity option is absent. Preserve the historical
                    // fail-closed behavior instead of treating any matching
                    // executable as this session.
                    return false
                }
                return ManagedAgentSessionIdentity.sessionIDsMatch(
                    kind: snapshot.kind.rawValue,
                    lhs: observedSessionID,
                    rhs: snapshot.sessionId
                )
            case .piSessionFile:
                observedSessionID = firstValue(
                    after: ["--session", "--resume", "-r"],
                    in: arguments
                )
            case .grokSessionDirectory:
                observedSessionID = firstValue(
                    after: ["--session-id", "--session", "--resume", "-r"],
                    in: arguments
                )
            case .persistedStore:
                // Hermes is validated in the dedicated branch above.
                observedSessionID = nil
            }
            guard let observedSessionID else { return true }
            return ManagedAgentSessionIdentity.sessionIDsMatch(
                kind: snapshot.kind.rawValue,
                lhs: observedSessionID,
                rhs: snapshot.sessionId
            )
        }
        let observedSessionID: String?
        switch snapshot.kind {
        case .claude:
            observedSessionID = firstValue(
                after: ["--session-id", "--resume", "-r"],
                in: arguments
            )
        case .codex:
            observedSessionID = firstValue(
                after: ["--session-id", "--session", "--resume", "-r"],
                orSubcommand: "resume",
                in: arguments
            )
        default:
            observedSessionID = nil
        }
        guard let observedSessionID else { return true }
        return ManagedAgentSessionIdentity.sessionIDsMatch(
            kind: snapshot.kind.rawValue,
            lhs: observedSessionID,
            rhs: snapshot.sessionId
        )
    }

    private func firstValue(
        after options: [String],
        orSubcommand subcommand: String? = nil,
        in arguments: [String]
    ) -> String? {
        for option in options {
            if let value = nonOptionValue(after: option, in: arguments) {
                return value
            }
        }
        guard let subcommand,
              let index = arguments.firstIndex(of: subcommand) else {
            return nil
        }
        let next = arguments.index(after: index)
        guard next < arguments.endIndex else { return nil }
        let value = arguments[next].trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty || value.hasPrefix("-") ? nil : value
    }

    private func recordedExecutableBasename(_ snapshot: SessionRestorableAgentSnapshot) -> String? {
        let executable = normalizedProcessValue(snapshot.launchCommand?.executablePath)
            ?? normalizedProcessValue(snapshot.launchCommand?.arguments.first)
            ?? normalizedProcessValue(snapshot.registration?.defaultExecutable)
        return executable.map(executableBasename)
    }

    private func liveProcessExecutableMatchesRecordedAgent(
        kind: RestorableAgentKind,
        liveExecutable: String,
        recordedExecutable: String,
        arguments: [String],
        environment: [String: String]
    ) -> Bool {
        if liveExecutable.compare(recordedExecutable, options: [.caseInsensitive, .literal]) == .orderedSame {
            return true
        }
        if Self.liveProcessMatchesLaunchExecutableEnvironment(
            kind: kind,
            executableCandidates: [liveExecutable],
            environment: environment
        ) {
            return true
        }
        if kind == .opencode, arguments.contains(where: argumentLooksLikeOpenCode) {
            return true
        }
        return Self.liveClaudeProcessExecutableMatches(kind: kind, liveExecutable: liveExecutable, arguments: arguments)
            || Self.liveCodexProcessExecutableMatches(kind: kind, liveExecutable: liveExecutable, arguments: arguments)
    }

    static func liveClaudeProcessExecutableMatches(
        kind: RestorableAgentKind,
        liveExecutable: String,
        arguments: [String]
    ) -> Bool {
        guard kind == .claude else { return false }
        let liveBase = liveExecutable.lowercased()
        guard liveBase == "node" || liveBase == "bun" else { return false }
        return arguments.dropFirst().contains { argument in
            let lowered = argument.lowercased()
            return executableBasename(argument).compare("claude", options: [.caseInsensitive, .literal]) == .orderedSame
                || lowered.contains("/.claude/")
                || lowered.contains("/claude/versions/")
        }
    }

    static func liveCodexProcessExecutableMatches(
        kind: RestorableAgentKind,
        liveExecutable: String,
        arguments: [String]
    ) -> Bool {
        guard kind == .codex else { return false }
        let liveBase = liveExecutable.lowercased()
        guard liveBase == "node" || liveBase == "bun" else { return false }
        return arguments.dropFirst().contains { argument in
            let lowered = argument.lowercased()
            return executableBasename(argument).compare("codex", options: [.caseInsensitive, .literal]) == .orderedSame
                || lowered.contains("@openai/codex")
                || lowered.contains("oh-my-codex")
        }
    }

    static func launchKind(_ liveKind: String, matches kind: RestorableAgentKind, launcher: String?) -> Bool {
        if liveKind.compare(kind.rawValue, options: [.caseInsensitive, .literal]) == .orderedSame {
            return true
        }
        guard let launcher = normalizedProcessValue(launcher),
              launcher.compare(liveKind, options: [.caseInsensitive, .literal]) == .orderedSame else {
            return false
        }
        return AgentLaunchCaptureTrust.launcherDescribesKind(liveKind, kind: kind.rawValue)
    }

    static func liveProcessMatchesLaunchExecutableEnvironment(
        kind: RestorableAgentKind,
        executableCandidates: [String],
        environment: [String: String]
    ) -> Bool {
        guard let liveKind = normalizedProcessValue(environment["CMUX_AGENT_LAUNCH_KIND"]),
              (liveKind.compare(kind.rawValue, options: [.caseInsensitive, .literal]) == .orderedSame
                  || AgentLaunchCaptureTrust.launcherDescribesKind(liveKind, kind: kind.rawValue)),
              let launchExecutable = normalizedProcessValue(environment["CMUX_AGENT_LAUNCH_EXECUTABLE"]) else {
            return false
        }
        let launchBasename = executableBasename(launchExecutable)
        return executableCandidates.contains { candidate in
            executableBasename(candidate).compare(launchBasename, options: [.caseInsensitive, .literal]) == .orderedSame
        }
    }

    private func registrationDetectRule(
        _ rule: CmuxVaultAgentDetectRule,
        matchesExecutable liveExecutable: String,
        arguments: [String]
    ) -> Bool {
        rule.matches(VaultObservedAgentProcess(
            processName: liveExecutable,
            processPath: nil,
            arguments: arguments,
            environment: [:]
        ))
    }

    private func argumentLooksLikeOpenCode(_ argument: String) -> Bool {
        switch executableBasename(argument).lowercased() {
        case "opencode", ".opencode", "opencode-ai", "open-code":
            return true
        default:
            return false
        }
    }

    private func nonOptionValue(after option: String, in arguments: [String]) -> String? {
        for index in arguments.indices {
            let argument = arguments[index]
            if argument == option {
                let nextIndex = arguments.index(after: index)
                guard nextIndex < arguments.endIndex else { return nil }
                let value = arguments[nextIndex].trimmingCharacters(in: .whitespacesAndNewlines)
                return !value.isEmpty && !value.hasPrefix("-") ? value : nil
            }
            let prefix = option + "="
            guard argument.hasPrefix(prefix) else { continue }
            let value = String(argument.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            return !value.isEmpty && !value.hasPrefix("-") ? value : nil
        }
        return nil
    }

    private static func executableBasename(_ value: String) -> String {
        (value as NSString).lastPathComponent
    }

    private func executableBasename(_ value: String) -> String {
        Self.executableBasename(value)
    }

    private static func normalizedProcessValue(_ value: String?) -> String? {
        guard let rawValue = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.isEmpty else {
            return nil
        }
        return rawValue
    }

    private func normalizedProcessValue(_ value: String?) -> String? {
        Self.normalizedProcessValue(value)
    }
}
