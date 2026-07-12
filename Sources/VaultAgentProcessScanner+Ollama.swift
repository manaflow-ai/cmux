import CMUXAgentLaunch
import Foundation

extension RestorableAgentSessionIndex {
    static func processDetectedOllamaSnapshots(
        processSnapshot: CmuxTopProcessSnapshot,
        capturedAt: TimeInterval,
        scopedProcessIDsByPanelKey: [PanelKey: Set<Int>],
        processArgumentsProvider: (Int) -> CmuxTopProcessArguments?,
        interactiveStdioProbe: (Int) -> Bool = processHasInteractiveTerminalStdio
    ) -> [PanelKey: ProcessDetectedSnapshotEntry] {
        var results: [PanelKey: ProcessDetectedSnapshotEntry] = [:]
        for process in processSnapshot.cmuxScopedProcesses() {
            // This snapshot is persisted and auto-executed on restore, so the
            // identity gate uses only the kernel-reported executable path:
            // CMUX_AGENT_LAUNCH_KIND and argv are user-controlled and must
            // not decide what gets relaunched. Fail closed without a path.
            guard process.isTerminalForegroundProcessGroup,
                  let workspaceID = process.cmuxWorkspaceID,
                  let surfaceID = process.cmuxSurfaceID,
                  let executablePath = process.path?.trimmingCharacters(in: .whitespacesAndNewlines),
                  (executablePath as NSString).lastPathComponent == "ollama",
                  let details = processArgumentsProvider(process.pid),
                  CmuxTaskManagerCodingAgentDefinition.matchingDefinition(
                      processName: process.name,
                      processPath: executablePath,
                      arguments: details.arguments,
                      environment: details.environment
                  )?.id == "ollama",
                  interactiveStdioProbe(process.pid),
                  let sanitizedArguments = AgentLaunchSanitizer.sanitizedLaunchArguments(
                      details.arguments,
                      launcher: "",
                      fallbackKind: "ollama"
                  ) else {
                continue
            }

            let workingDirectory = normalizedOllamaValue(
                details.environment["CMUX_AGENT_LAUNCH_CWD"] ?? details.environment["PWD"]
            )
            let key = PanelKey(workspaceId: workspaceID, panelId: surfaceID)
            // Relaunch through the trusted kernel path, never argv[0].
            let launchCommand = AgentLaunchCommandSnapshot(
                processDetectedLauncher: "ollama",
                executablePath: executablePath,
                arguments: [executablePath] + sanitizedArguments.dropFirst(),
                workingDirectory: workingDirectory,
                environment: details.environment
            )
            results[key] = (
                snapshot: SessionRestorableAgentSnapshot(
                    kind: .ollama,
                    sessionId: "",
                    workingDirectory: workingDirectory,
                    launchCommand: launchCommand,
                    registration: nil
                ),
                updatedAt: capturedAt,
                processIDs: scopedProcessIDsByPanelKey[key] ?? [process.pid],
                agentProcessIDs: [process.pid],
                sessionIDSource: .relaunchOnly
            )
        }
        return results
    }

    private static func normalizedOllamaValue(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    /// Ollama decides interactivity from its stdio terminals, not argv:
    /// `cat prompt | ollama run model` and `ollama run model > out` carry the
    /// interactive argv but are one-shot batch jobs whose pipe or file
    /// redirection cannot be restored as a REPL. Require both stdin and
    /// stdout to be TTY vnodes and fail closed when a descriptor cannot be
    /// inspected.
    static func processHasInteractiveTerminalStdio(pid: Int) -> Bool {
        stdioFDIsTerminal(pid: pid, fd: 0) && stdioFDIsTerminal(pid: pid, fd: 1)
    }

    private static func stdioFDIsTerminal(pid: Int, fd: Int32) -> Bool {
        var info = vnode_fdinfowithpath()
        let size = proc_pidfdinfo(
            pid_t(pid),
            fd,
            PROC_PIDFDVNODEPATHINFO,
            &info,
            Int32(MemoryLayout<vnode_fdinfowithpath>.size)
        )
        // Pipes and other non-vnode descriptors fail this query, which is
        // exactly the fail-closed answer.
        guard size > 0 else { return false }
        let path = withUnsafeBytes(of: &info.pvip.vip_path) { raw -> String in
            guard let base = raw.baseAddress else { return "" }
            return String(cString: base.assumingMemoryBound(to: CChar.self))
        }
        return path.hasPrefix("/dev/tty")
    }
}
