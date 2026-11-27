import Foundation
import CMUXAgentLaunch

extension RestorableAgentSessionIndex {
    static func forkParentFallbackWrapperLaunch(
        processName: String,
        processPath: String?,
        arguments: [String],
        environment: [String: String]
    ) -> (
        kind: RestorableAgentKind,
        parentSessionId: String,
        launcher: String,
        launchCommand: (executablePath: String, arguments: [String])
    )? {
        guard wrapperProcessLooksLikeCmuxCLI(
            processName: processName,
            processPath: processPath,
            arguments: arguments,
            environment: environment
        ) else {
            return nil
        }
        if let codexTeams = wrapperCodexTeamsFallback(arguments: arguments) {
            return codexTeams
        }
        return nil
    }

    private static func wrapperCodexTeamsFallback(
        arguments: [String]
    ) -> (
        kind: RestorableAgentKind,
        parentSessionId: String,
        launcher: String,
        launchCommand: (executablePath: String, arguments: [String])
    )? {
        guard let subcommandIndex = arguments.firstIndex(of: "codex-teams"),
              arguments.index(subcommandIndex, offsetBy: 2, limitedBy: arguments.endIndex) != nil else {
            return nil
        }
        let forkIndex = arguments.index(after: subcommandIndex)
        let sessionIndex = arguments.index(after: forkIndex)
        guard forkIndex < arguments.endIndex,
              sessionIndex < arguments.endIndex,
              arguments[forkIndex] == "fork",
              let parentSessionId = normalizedWrapperUUID(arguments[sessionIndex]) else {
            return nil
        }
        let tail = Array(arguments[arguments.index(after: subcommandIndex)...])
        guard let preserved = AgentLaunchSanitizer.preservedArguments(kind: "codex-fork-replay", args: tail) else {
            return nil
        }
        // codex-teams keeps the cmux wrapper process alive; its exec-time env does
        // not carry CMUX_AGENT_LAUNCH_KIND, so cached validation has no teams/base
        // kind mismatch to reject.
        let executable = wrapperExecutable(arguments: arguments)
        return (
            .codex,
            parentSessionId,
            "codexTeams",
            (executable, [executable, "codex-teams"] + preserved)
        )
    }

    private static func wrapperProcessLooksLikeCmuxCLI(
        processName: String,
        processPath: String?,
        arguments: [String],
        environment: [String: String]
    ) -> Bool {
        let bundledCLIPath = normalizedWrapperValue(environment["CMUX_BUNDLED_CLI_PATH"])
        let candidates = [arguments.first, processPath, processName].compactMap(normalizedWrapperValue)
        return candidates.contains { candidate in
            executableBasename(candidate).compare("cmux", options: [.caseInsensitive, .literal]) == .orderedSame
                || bundledCLIPath.map { ($0 as NSString).standardizingPath == (candidate as NSString).standardizingPath } == true
        }
    }

    private static func wrapperExecutable(arguments: [String]) -> String {
        normalizedWrapperValue(arguments.first) ?? "cmux"
    }

    private static func normalizedWrapperUUID(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.hasPrefix("-"),
              UUID(uuidString: trimmed) != nil else {
            return nil
        }
        return trimmed
    }

    private static func normalizedWrapperValue(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private static func executableBasename(_ value: String) -> String {
        (value as NSString).lastPathComponent
    }

}
