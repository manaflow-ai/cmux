import CMUXAgentLaunch
import CmuxAgentChat
import Foundation

extension AgentChatSessionRegistry {
    nonisolated static func allowsLaunchKindEnvironment(
        for process: CmuxTopProcessInfo,
        rootPIDs: Set<Int>,
        arguments: [String]?
    ) -> Bool {
        if rootPIDs.contains(process.pid) {
            return true
        }
        guard process.isTerminalForegroundProcessGroup,
              process.processGroupID == process.pid,
              let arguments else {
            return false
        }
        if CmuxTaskManagerCodingAgentDefinition.matchingDefinition(
            processName: process.name,
            processPath: process.path,
            arguments: arguments,
            environment: [:]
        ) != nil {
            return true
        }
        return arguments.dropFirst().contains { argument in
            normalizedObserverValue(argument)?.contains("/.cmux-agent-wrapper/") == true
        }
    }

    nonisolated static func codingAgentDefinition(
        for process: CmuxTopProcessInfo,
        allowLaunchKindEnvironment: Bool,
        processArgumentsAndEnvironment: (Int) -> CmuxTopProcessArguments?
    ) -> CmuxTaskManagerCodingAgentDefinition? {
        let shouldReadDetails = CmuxTaskManagerCodingAgentDefinition.shouldReadArguments(
            processName: process.name,
            processPath: process.path
        )
        if let direct = authoritativeCodingAgentDefinition(
            processName: process.name,
            processPath: process.path,
            arguments: [],
            environment: [:],
            allowLaunchKindEnvironment: false
        ) {
            return direct
        }
        if !shouldReadDetails { return nil }
        guard let details = processArgumentsAndEnvironment(process.pid) else {
            return nil
        }
        return authoritativeCodingAgentDefinition(
            processName: process.name,
            processPath: process.path,
            arguments: details.arguments,
            environment: details.environment,
            allowLaunchKindEnvironment: allowLaunchKindEnvironment
        )
    }

    private nonisolated static func authoritativeCodingAgentDefinition(
        processName: String,
        processPath: String?,
        arguments: [String],
        environment: [String: String],
        allowLaunchKindEnvironment: Bool
    ) -> CmuxTaskManagerCodingAgentDefinition? {
        let definitions = CmuxTaskManagerCodingAgentDefinition.builtIns
        if allowLaunchKindEnvironment,
           let launchKind = normalizedObserverValue(environment["CMUX_AGENT_LAUNCH_KIND"]),
           let def = definitions.first(where: { $0.launchKinds.contains(launchKind) }) {
            return def
        }
        let basenames = Set([processName, processPath, arguments.first].compactMap(observerBasename))
        if let def = definitions.first(where: { def in basenames.contains { def.directBasenames.contains($0) } }) {
            return def
        }
        guard let path = normalizedObserverValue(processPath) else { return nil }
        return definitions.first { def in
            def.argumentNeedles.contains { needle in
                guard needle.hasSuffix("/"),
                      let normalizedNeedle = normalizedObserverValue(needle) else { return false }
                return path.contains(normalizedNeedle)
            }
        }
    }

    private nonisolated static func observerBasename(_ value: String?) -> String? {
        normalizedObserverValue(value.map { ($0 as NSString).lastPathComponent })
    }

    private nonisolated static func normalizedObserverValue(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    nonisolated static func observedWorkingDirectory(_ environment: [String: String]?) -> String? {
        guard let environment else { return nil }
        for key in ["CMUX_AGENT_LAUNCH_CWD", "PWD"] {
            if let value = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !value.isEmpty {
                return value
            }
        }
        return nil
    }

    nonisolated static func sessionIDFromArguments(_ arguments: [String]) -> String? {
        var index = 0
        while index < arguments.count {
            let arg = arguments[index]
            if ["--session-id", "--resume", "-r"].contains(arg),
               index + 1 < arguments.count,
               let id = sessionIDFromOptionValue(arguments[index + 1]) {
                return id
            }
            for prefix in ["--session-id=", "--resume=", "-r="] where arg.hasPrefix(prefix) {
                if let id = sessionIDFromOptionValue(String(arg.dropFirst(prefix.count))) {
                    return id
                }
            }
            index += 1
        }
        return nil
    }

    nonisolated static func containsExplicitSessionOption(_ arguments: [String]) -> Bool {
        arguments.contains { argument in
            argument == "--session-id"
                || argument == "--resume"
                || argument == "-r"
                || argument.hasPrefix("--session-id=")
                || argument.hasPrefix("--resume=")
                || argument.hasPrefix("-r=")
        }
    }
    nonisolated static func containsClaudeForkSessionOption(_ arguments: [String]) -> Bool {
        arguments.contains { argument in
            let value = argument.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return value == "--fork-session" || value.hasPrefix("--fork-session=")
        }
    }

    private nonisolated static func sessionIDFromOptionValue(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.hasPrefix("-") else { return nil }
        return firstUUIDLike(in: trimmed)
    }
    /// libproc: the path of a `~/.codex/sessions/**/rollout-*.jsonl` the process
    /// holds open (codex keeps its rollout open for writing), or nil.
    nonisolated static func openCodexRolloutPath(pid: Int) -> String? {
        let listSize = proc_pidinfo(pid_t(pid), PROC_PIDLISTFDS, 0, nil, 0)
        guard listSize > 0 else { return nil }
        let count = Int(listSize) / MemoryLayout<proc_fdinfo>.stride
        guard count > 0 else { return nil }
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: count)
        let used = proc_pidinfo(pid_t(pid), PROC_PIDLISTFDS, 0, &fds, listSize)
        guard used > 0 else { return nil }
        let actual = Int(used) / MemoryLayout<proc_fdinfo>.stride
        for index in 0..<min(actual, fds.count) {
            guard fds[index].proc_fdtype == UInt32(PROX_FDTYPE_VNODE) else { continue }
            var info = vnode_fdinfowithpath()
            let size = proc_pidfdinfo(
                pid_t(pid),
                fds[index].proc_fd,
                PROC_PIDFDVNODEPATHINFO,
                &info,
                Int32(MemoryLayout<vnode_fdinfowithpath>.size)
            )
            guard size > 0 else { continue }
            let path = withUnsafeBytes(of: &info.pvip.vip_path) { raw -> String in
                guard let base = raw.baseAddress else { return "" }
                return String(cString: base.assumingMemoryBound(to: CChar.self))
            }
            if path.hasSuffix(".jsonl"), path.contains("/.codex/sessions/") {
                return path
            }
        }
        return nil
    }

    private nonisolated static let uuidLikeRegex = try? NSRegularExpression(
        pattern: "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"
    )

    /// The first UUID-shaped substring (matches both standard UUIDs and codex's
    /// UUIDv7 rollout ids), or nil.
    nonisolated static func firstUUIDLike(in string: String) -> String? {
        guard let regex = uuidLikeRegex else { return nil }
        let range = NSRange(string.startIndex..., in: string)
        guard let match = regex.firstMatch(in: string, options: [], range: range),
              let matchRange = Range(match.range, in: string) else { return nil }
        return String(string[matchRange])
    }
}
