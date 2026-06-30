import CMUXAgentLaunch
import CmuxAgentChat
import Foundation

extension AgentChatSessionRegistry {
    nonisolated static func scanObservedAgentSessions(
        in snapshot: CmuxTopProcessSnapshot,
        processArgumentsAndEnvironment: (Int) -> CmuxTopProcessArguments?,
        codexRolloutPath: (Int) -> String?
    ) -> [ObservedAgentSession] {
        var result: [ObservedAgentSession] = []
        var seen = Set<String>()
        for process in snapshot.cmuxScopedProcesses() {
            var details: CmuxTopProcessArguments?
            func loadDetails() -> CmuxTopProcessArguments? {
                if details == nil {
                    details = processArgumentsAndEnvironment(process.pid)
                }
                return details
            }
            guard let surfaceID = process.cmuxSurfaceID,
                  let def = codingAgentDefinition(
                      for: process,
                      processArgumentsAndEnvironment: { _ in loadDetails() }
                  ),
                  def.id == "codex" || def.id == "claude" else { continue }
            var sessionID: String?
            var transcriptPath: String?
            if def.id == "codex", let rollout = codexRolloutPath(process.pid) {
                transcriptPath = rollout
                sessionID = firstUUIDLike(in: (rollout as NSString).lastPathComponent)
            }
            if def.id == "claude",
               let envSessionID = loadDetails()?.environment["CLAUDE_CODE_SESSION_ID"],
               let id = firstUUIDLike(in: envSessionID) {
                sessionID = id
            }
            if sessionID == nil,
               let argv = loadDetails()?.arguments {
                sessionID = sessionIDFromArguments(argv)
            }
            guard let resolved = sessionID, !seen.contains(resolved) else { continue }
            seen.insert(resolved)
            result.append(ObservedAgentSession(
                sessionID: resolved,
                agentKind: ChatAgentKind(source: def.id),
                surfaceID: surfaceID.uuidString,
                workspaceID: process.cmuxWorkspaceID?.uuidString,
                pid: process.pid,
                workingDirectory: observedWorkingDirectory(details?.environment),
                transcriptPath: transcriptPath
            ))
        }
        return result
    }

    nonisolated static func codingAgentDefinition(
        for process: CmuxTopProcessInfo,
        processArgumentsAndEnvironment: (Int) -> CmuxTopProcessArguments?
    ) -> CmuxTaskManagerCodingAgentDefinition? {
        let shouldReadDetails = CmuxTaskManagerCodingAgentDefinition.shouldReadArguments(
            processName: process.name,
            processPath: process.path
        )
        if let direct = CmuxTaskManagerCodingAgentDefinition.matchingDefinition(
            processName: process.name,
            processPath: process.path,
            arguments: [],
            environment: [:]
        ) {
            return direct
        }
        if !shouldReadDetails {
            return nil
        }
        guard let details = processArgumentsAndEnvironment(process.pid) else {
            return nil
        }
        return CmuxTaskManagerCodingAgentDefinition.matchingDefinition(
            processName: process.name,
            processPath: process.path,
            arguments: details.arguments,
            environment: [:]
        )
    }

    private nonisolated static func observedWorkingDirectory(_ environment: [String: String]?) -> String? {
        guard let environment else { return nil }
        for key in ["CMUX_AGENT_LAUNCH_CWD", "PWD"] {
            if let value = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !value.isEmpty {
                return value
            }
        }
        return nil
    }

    /// Extracts a session id from an agent's argv (`--session-id <id>`,
    /// `--session-id=<id>`, `--resume <id>`, `--resume=<id>`).
    private nonisolated static func sessionIDFromArguments(_ arguments: [String]) -> String? {
        var index = 0
        while index < arguments.count {
            let arg = arguments[index]
            if arg == "--session-id" || arg == "--resume", index + 1 < arguments.count,
               let id = firstUUIDLike(in: arguments[index + 1]) {
                return id
            }
            if arg.hasPrefix("--session-id="),
               let id = firstUUIDLike(in: String(arg.dropFirst("--session-id=".count))) {
                return id
            }
            if arg.hasPrefix("--resume="),
               let id = firstUUIDLike(in: String(arg.dropFirst("--resume=".count))) {
                return id
            }
            index += 1
        }
        return nil
    }

    private nonisolated static let uuidLikeRegex = try? NSRegularExpression(
        pattern: "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"
    )

    /// The first UUID-shaped substring (matches both standard UUIDs and codex's
    /// UUIDv7 rollout ids), or nil.
    private nonisolated static func firstUUIDLike(in string: String) -> String? {
        guard let regex = uuidLikeRegex else { return nil }
        let range = NSRange(string.startIndex..., in: string)
        guard let match = regex.firstMatch(in: string, options: [], range: range),
              let matchRange = Range(match.range, in: string) else { return nil }
        return String(string[matchRange])
    }
}
