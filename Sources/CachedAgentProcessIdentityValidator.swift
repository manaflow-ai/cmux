import Foundation

struct CachedAgentProcessIdentityValidator: Sendable {
    func currentProcess(
        _ process: CmuxTopProcessArguments,
        matches snapshot: SessionRestorableAgentSnapshot
    ) -> Bool {
        if let liveKind = normalizedProcessValue(process.environment["CMUX_AGENT_LAUNCH_KIND"]),
           liveKind.compare(snapshot.kind.rawValue, options: [.caseInsensitive, .literal]) != .orderedSame {
            return false
        }
        guard currentProcessExecutable(process.arguments, matches: snapshot) else {
            return false
        }
        return currentProcessSession(process.arguments, matches: snapshot)
    }

    private func currentProcessExecutable(
        _ arguments: [String],
        matches snapshot: SessionRestorableAgentSnapshot
    ) -> Bool {
        guard let liveExecutable = arguments.first.map(executableBasename) else { return false }
        if let recordedExecutable = recordedExecutableBasename(snapshot),
           liveProcessExecutableMatchesRecordedAgent(
               kind: snapshot.kind,
               liveExecutable: liveExecutable,
               recordedExecutable: recordedExecutable,
               arguments: arguments
           ) {
            return true
        }
        guard let registration = snapshot.registration else {
            return liveProcessExecutableMatchesRecordedAgent(
                kind: snapshot.kind,
                liveExecutable: liveExecutable,
                recordedExecutable: snapshot.kind.rawValue,
                arguments: arguments
            )
        }
        return registrationDetectRule(registration.detect, matchesExecutable: liveExecutable, arguments: arguments)
    }

    private func currentProcessSession(
        _ arguments: [String],
        matches snapshot: SessionRestorableAgentSnapshot
    ) -> Bool {
        guard let registration = snapshot.registration else { return true }
        guard case .argvOption(let option) = registration.sessionIdSource else { return true }
        return nonOptionValue(after: option, in: arguments) == snapshot.sessionId
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
        arguments: [String]
    ) -> Bool {
        if liveExecutable.compare(recordedExecutable, options: [.caseInsensitive, .literal]) == .orderedSame {
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

    private func registrationDetectRule(
        _ rule: CmuxVaultAgentDetectRule,
        matchesExecutable liveExecutable: String,
        arguments: [String]
    ) -> Bool {
        var expectedNames = rule.processNames
        if let processName = normalizedProcessValue(rule.processName) {
            expectedNames.append(processName)
        }
        let processNameMatch = expectedNames.isEmpty || expectedNames.contains { expected in
            liveExecutable.compare(expected, options: [.caseInsensitive, .literal]) == .orderedSame
        }
        let argvContainsMatch = rule.argvContains.isEmpty || argumentsContainAll(rule.argvContains, in: arguments)
        let alternateArgvContainsMatch = !rule.alternateArgvContains.isEmpty
            && argumentsContainAll(rule.alternateArgvContains, in: arguments)
        return (processNameMatch && argvContainsMatch) || alternateArgvContainsMatch
    }

    private func argumentsContainAll(_ needles: [String], in arguments: [String]) -> Bool {
        needles.allSatisfy { needle in
            if needle.contains(" ") {
                return arguments.joined(separator: " ").range(of: needle, options: [.caseInsensitive, .literal]) != nil
            }
            if needle.contains("/") {
                return arguments.joined(separator: "\u{0}").range(of: needle, options: [.caseInsensitive, .literal]) != nil
            }
            return arguments.contains { argument in
                argument.range(of: needle, options: [.caseInsensitive, .literal]) != nil
                    || executableBasename(argument).range(of: needle, options: [.caseInsensitive, .literal]) != nil
            }
        }
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

    private func normalizedProcessValue(_ value: String?) -> String? {
        guard let rawValue = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.isEmpty else {
            return nil
        }
        return rawValue
    }
}
