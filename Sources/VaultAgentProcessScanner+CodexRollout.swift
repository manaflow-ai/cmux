import CMUXAgentLaunch
import Darwin
import Foundation

enum CodexRolloutProcessResolver {
    /// Codex keeps the active rollout open for appending. Older rollouts may also
    /// remain open read-only, so only a writable rollout identifies this process's
    /// current conversation. When subagents also have writable rollouts, their
    /// session metadata identifies the single root conversation.
    static func openWritableRolloutPath(pid: Int) -> String? {
        let listSize = proc_pidinfo(pid_t(pid), PROC_PIDLISTFDS, 0, nil, 0)
        guard listSize > 0 else { return nil }
        let count = Int(listSize) / MemoryLayout<proc_fdinfo>.stride
        guard count > 0 else { return nil }
        var fileDescriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: count)
        let used = proc_pidinfo(pid_t(pid), PROC_PIDLISTFDS, 0, &fileDescriptors, listSize)
        guard used > 0 else { return nil }

        let actualCount = Int(used) / MemoryLayout<proc_fdinfo>.stride
        var writableRolloutPaths = Set<String>()
        for fileDescriptor in fileDescriptors.prefix(min(actualCount, fileDescriptors.count)) {
            guard fileDescriptor.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) else { continue }
            var info = vnode_fdinfowithpath()
            let size = proc_pidfdinfo(
                pid_t(pid),
                fileDescriptor.proc_fd,
                PROC_PIDFDVNODEPATHINFO,
                &info,
                Int32(MemoryLayout<vnode_fdinfowithpath>.size)
            )
            guard size > 0,
                  info.pfi.fi_openflags & UInt32(FWRITE) != 0 else {
                continue
            }
            let path = withUnsafeBytes(of: &info.pvip.vip_path) { raw -> String in
                guard let baseAddress = raw.baseAddress else { return "" }
                return String(cString: baseAddress.assumingMemoryBound(to: CChar.self))
            }
            let url = URL(fileURLWithPath: path, isDirectory: false)
            let filename = url.lastPathComponent
            guard filename.hasPrefix("rollout-"),
                  filename.hasSuffix(".jsonl"),
                  firstUUIDLike(in: filename) != nil,
                  url.deletingLastPathComponent().pathComponents.contains("sessions") else {
                continue
            }
            writableRolloutPaths.insert((path as NSString).standardizingPath)
        }
        if writableRolloutPaths.count == 1 {
            return writableRolloutPaths.first
        }

        let classified = writableRolloutPaths.compactMap { path -> (String, RolloutLineage)? in
            guard let lineage = rolloutLineage(path: path) else { return nil }
            return (path, lineage)
        }
        guard classified.count == writableRolloutPaths.count else { return nil }
        let roots = classified.compactMap { path, lineage in
            lineage == .root ? path : nil
        }
        return roots.count == 1 ? roots[0] : nil
    }

    static func firstUUIDLike(in string: String) -> String? {
        guard let regex = uuidLikeRegex else { return nil }
        let range = NSRange(string.startIndex..., in: string)
        guard let match = regex.firstMatch(in: string, options: [], range: range),
              let matchRange = Range(match.range, in: string) else {
            return nil
        }
        return String(string[matchRange])
    }

    private static let uuidLikeRegex = try? NSRegularExpression(
        pattern: "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"
    )

    private enum RolloutLineage {
        case root
        case subagent
    }

    private static func rolloutLineage(path: String) -> RolloutLineage? {
        let url = URL(fileURLWithPath: path, isDirectory: false)
        guard let filenameSessionId = firstUUIDLike(in: url.lastPathComponent),
              let handle = try? FileHandle(forReadingFrom: url) else {
            return nil
        }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 64 * 1024),
              !head.isEmpty else {
            return nil
        }
        let firstLineEnd = head.firstIndex(of: 0x0A) ?? head.endIndex
        let firstLine = head[..<firstLineEnd]
        guard let object = try? JSONSerialization.jsonObject(with: Data(firstLine)) as? [String: Any],
              object["type"] as? String == "session_meta",
              let payload = object["payload"] as? [String: Any],
              let metadataSessionId = payload["id"] as? String,
              metadataSessionId.caseInsensitiveCompare(filenameSessionId) == .orderedSame else {
            return nil
        }
        if let parentThreadId = payload["parent_thread_id"] as? String,
           !parentThreadId.isEmpty {
            return .subagent
        }
        if payload["thread_source"] as? String == "subagent" {
            return .subagent
        }
        if let source = payload["source"] as? [String: Any],
           source["subagent"] != nil {
            return .subagent
        }
        return .root
    }
}

extension RestorableAgentSessionIndex {
    static func processDetectedCodexSnapshots(
        processSnapshot: CmuxTopProcessSnapshot,
        capturedAt: TimeInterval,
        scopedProcessIDsByPanelKey: [PanelKey: Set<Int>],
        processArgumentsProvider: (Int) -> CmuxTopProcessArguments?,
        codexRolloutPathProvider: (Int) -> String?
    ) -> [PanelKey: ProcessDetectedSnapshotEntry] {
        var candidatesByPanel: [PanelKey: [ProcessDetectedSnapshotEntry]] = [:]

        for process in processSnapshot.cmuxScopedProcesses() {
            guard let workspaceId = process.cmuxWorkspaceID,
                  let panelId = process.cmuxSurfaceID,
                  process.isTerminalForegroundProcessGroup,
                  let processArguments = processArgumentsProvider(process.pid),
                  processLooksLikeCodex(
                      processName: process.name,
                      processPath: process.path,
                      arguments: processArguments.arguments,
                      environment: processArguments.environment
                  ),
                  let rolloutPath = codexRolloutPathProvider(process.pid),
                  let sessionId = CodexRolloutProcessResolver.firstUUIDLike(
                      in: (rolloutPath as NSString).lastPathComponent
                  ) else {
                continue
            }

            let environment = processArguments.environment
            let trustedLiveExecutable = matchingCapturedCodexExecutable(
                arguments: processArguments.arguments,
                processPath: process.path,
                environment: environment
            )
            let capturedLaunchArguments = trustedCapturedCodexLaunchArguments(
                liveArguments: processArguments.arguments,
                processPath: process.path,
                environment: environment
            )
            let launchArguments = capturedLaunchArguments ?? processArguments.arguments
            var launchEnvironment = environment
            if capturedLaunchArguments == nil {
                launchEnvironment.removeValue(forKey: "CMUX_AGENT_LAUNCH_ARGV_B64")
                launchEnvironment.removeValue(forKey: "CMUX_AGENT_LAUNCH_CWD")
                if trustedLiveExecutable == nil {
                    launchEnvironment.removeValue(forKey: "CMUX_AGENT_LAUNCH_KIND")
                    launchEnvironment.removeValue(forKey: "CMUX_AGENT_LAUNCH_EXECUTABLE")
                }
            }
            guard let launchCommand = processDetectedCodexLaunchCommand(
                processName: process.name,
                processPath: process.path,
                arguments: launchArguments,
                environment: launchEnvironment
            ) else {
                continue
            }

            let cwd = normalizedCodexValue(environment["PWD"])
                ?? (capturedLaunchArguments == nil
                    ? nil
                    : normalizedCodexValue(environment["CMUX_AGENT_LAUNCH_CWD"]))
            let key = PanelKey(workspaceId: workspaceId, panelId: panelId)
            let snapshot = SessionRestorableAgentSnapshot(
                kind: .codex,
                sessionId: sessionId,
                workingDirectory: cwd,
                launchCommand: AgentLaunchCommandSnapshot(
                    processDetectedLauncher: "codex",
                    executablePath: launchCommand.executablePath,
                    arguments: launchCommand.arguments,
                    workingDirectory: cwd,
                    environment: launchEnvironment
                )
            )
            candidatesByPanel[key, default: []].append((
                snapshot: snapshot,
                updatedAt: capturedAt,
                processIDs: scopedProcessIDsByPanelKey[key] ?? [],
                agentProcessIDs: [process.pid],
                sessionIDSource: .explicit
            ))
        }

        var resolved: [PanelKey: ProcessDetectedSnapshotEntry] = [:]
        for (key, candidates) in candidatesByPanel {
            guard Set(candidates.map { $0.snapshot.sessionId }).count == 1,
                  var selected = candidates.min(by: {
                      ($0.agentProcessIDs.min() ?? Int.max) < ($1.agentProcessIDs.min() ?? Int.max)
                  }) else {
                continue
            }
            selected.processIDs = candidates.reduce(into: Set<Int>()) { result, candidate in
                result.formUnion(candidate.processIDs)
            }
            selected.agentProcessIDs = candidates.reduce(into: Set<Int>()) { result, candidate in
                result.formUnion(candidate.agentProcessIDs)
            }
            resolved[key] = selected
        }
        return resolved
    }

    private static func trustedCapturedCodexLaunchArguments(
        liveArguments: [String],
        processPath: String?,
        environment: [String: String]
    ) -> [String]? {
        guard let capturedArguments = decodedNULSeparatedLaunchArguments(
                  environment["CMUX_AGENT_LAUNCH_ARGV_B64"]
              ),
              let capturedExecutable = matchingCapturedCodexExecutable(
                  arguments: capturedArguments,
                  environment: environment
              ) else {
            return nil
        }
        let capturedTail = capturedArguments.dropFirst()
        let liveTail = liveArguments.dropFirst()
        if capturedTail.isEmpty {
            let liveExecutableCandidates = [liveArguments.first, processPath]
                .compactMap { normalizedCodexValue($0) }
            guard liveExecutableCandidates.contains(where: {
                ($0 as NSString).standardizingPath
                    == (capturedExecutable as NSString).standardizingPath
            }) else {
                return nil
            }
        } else {
            guard liveTail.count >= capturedTail.count,
                  liveTail.suffix(capturedTail.count).elementsEqual(capturedTail) else {
                return nil
            }
        }
        return capturedArguments
    }

    static func matchingCapturedCodexExecutable(
        arguments: [String],
        processPath: String? = nil,
        environment: [String: String]
    ) -> String? {
        guard environmentLaunchKind(environment) == "codex",
              let capturedExecutable = normalizedCodexValue(environment["CMUX_AGENT_LAUNCH_EXECUTABLE"]) else {
            return nil
        }
        let liveCandidates = [arguments.first, processPath].compactMap { normalizedCodexValue($0) }
        guard liveCandidates.contains(where: {
            ($0 as NSString).standardizingPath
                == (capturedExecutable as NSString).standardizingPath
        }) else { return nil }
        return capturedExecutable
    }

    private static func normalizedCodexValue(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}
