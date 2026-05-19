import Foundation

extension CMUXCLI {
    struct MemoryProcessIdentity: Equatable {
        let pid: Int
        let startSeconds: Int
        let startMicroseconds: Int

        var payload: [String: Any] {
            [
                "pid": pid,
                "start_seconds": startSeconds,
                "start_microseconds": startMicroseconds
            ]
        }

        init?(process: [String: Any]) {
            guard let pid = CMUXCLI.topIntValue(process["pid"]),
                  let startSeconds = CMUXCLI.topIntValue(process["start_seconds"]),
                  let startMicroseconds = CMUXCLI.topIntValue(process["start_microseconds"]) else {
                return nil
            }
            self.pid = pid
            self.startSeconds = startSeconds
            self.startMicroseconds = startMicroseconds
        }
    }

    enum MemoryAgentCandidateSource: String {
        case tag
        case process
    }

    struct MemoryAgentCandidate {
        let key: String
        let pid: Int
        let surfaceId: String?
        let surfaceRef: String?
        let processName: String?
        let residentBytes: Int64
        let residentBytesKnown: Bool
        let source: MemoryAgentCandidateSource
        let identity: MemoryProcessIdentity?

        var owned: Bool {
            source == .tag
        }

        var displayName: String {
            processName.map { "\(key) (\($0))" } ?? key
        }

        var payload: [String: Any] {
            [
                "key": key,
                "pid": pid,
                "surface_id": surfaceId ?? NSNull(),
                "surface_ref": surfaceRef ?? NSNull(),
                "process_name": processName ?? NSNull(),
                "resident_bytes": residentBytes,
                "owned": owned,
                "process_identity": identity?.payload ?? NSNull()
            ]
        }
    }

    struct MemoryTrimResult {
        let workspaceId: String
        let workspaceRef: String?
        let agent: MemoryAgentCandidate
        let gracefulAction: String?
        let attemptedShutdown: Bool
        let terminated: Bool
        let killed: Bool
        let stillRunning: Bool
        let dryRun: Bool

        var payload: [String: Any] {
            [
                "workspace_id": workspaceId,
                "workspace_ref": workspaceRef ?? NSNull(),
                "agent": agent.payload,
                "graceful_action": gracefulAction ?? NSNull(),
                "attempted_shutdown": attemptedShutdown,
                "terminated": terminated,
                "killed": killed,
                "still_running": stillRunning,
                "dry_run": dryRun
            ]
        }
    }

    struct MemoryTrimmer {
        private static let postSignalWaitSeconds: TimeInterval = 1

        let cli: CMUXCLI
        let client: SocketClient
        private let parser: MemoryAgentParser
        private let signaler: MemoryProcessSignaler

        init(cli: CMUXCLI, client: SocketClient) {
            self.init(
                cli: cli,
                client: client,
                parser: MemoryAgentParser(cli: cli),
                signaler: MemoryProcessSignaler(client: client)
            )
        }

        init(
            cli: CMUXCLI,
            client: SocketClient,
            parser: MemoryAgentParser,
            signaler: MemoryProcessSignaler
        ) {
            self.cli = cli
            self.client = client
            self.parser = parser
            self.signaler = signaler
        }

        func trim(options: MemoryTrimCommandOptions) throws -> MemoryTrimResult {
            let workspaceHandle = try cli.normalizeWorkspaceHandle(
                options.workspaceHandle,
                client: client,
                allowCurrent: true
            )
            guard let workspaceHandle else {
                throw CLIError(message: String(
                    localized: "cli.memory.error.trimWorkspaceRequired",
                    defaultValue: "memory trim requires --workspace <id|ref|index> or a current workspace"
                ))
            }
            let payload = try cli.buildMemoryTopPayload(workspaceHandle: workspaceHandle, client: client)
            guard let workspace = parser.workspaceNode(from: payload, matching: workspaceHandle) else {
                throw CLIError(message: String(
                    localized: "cli.memory.error.workspaceNotFound",
                    defaultValue: "Workspace not found"
                ))
            }
            let workspaceId = (workspace["id"] as? String) ?? workspaceHandle
            let workspaceRef = workspace["ref"] as? String
            let candidates = parser.candidates(in: workspace)
            guard let candidate = try parser.selectCandidate(candidates, requested: options.agent) else {
                throw CLIError(message: parser.noAgentMessage(candidates: candidates, requested: options.agent))
            }

            let graceful = parser.gracefulExitAction(for: candidate)
            var gracefulAction: String?
            var terminated = false
            var killed = false
            var attemptedShutdown = false
            var processExited = false
            var canEscalateSignals = true

            if !options.dryRun {
                if let graceful {
                    do {
                        attemptedShutdown = true
                        try signaler.sendGracefulExit(graceful, workspaceId: workspaceId)
                        gracefulAction = graceful.label
                        processExited = signaler.waitForExit(pid: candidate.pid, timeout: options.graceSeconds)
                    } catch {
                        gracefulAction = nil
                    }
                }

                if !processExited, candidate.identity != nil, canEscalateSignals {
                    if let liveCandidate = try revalidatedSignalCandidate(
                        matching: candidate,
                        workspaceHandle: workspaceHandle,
                        tolerateMissingRevalidation: attemptedShutdown
                    ) {
                        attemptedShutdown = true
                        if signaler.sendTerminateSignal(pid: liveCandidate.pid) {
                            terminated = true
                        }
                        processExited = signaler.waitForExit(pid: liveCandidate.pid, timeout: Self.postSignalWaitSeconds)
                    } else {
                        processExited = !signaler.isRunning(pid: candidate.pid)
                        canEscalateSignals = false
                    }
                }

                if !processExited, candidate.identity != nil, canEscalateSignals {
                    if let liveCandidate = try revalidatedSignalCandidate(
                        matching: candidate,
                        workspaceHandle: workspaceHandle,
                        tolerateMissingRevalidation: attemptedShutdown
                    ) {
                        attemptedShutdown = true
                        if signaler.sendKillSignal(pid: liveCandidate.pid) {
                            killed = true
                        }
                        _ = signaler.waitForExit(pid: liveCandidate.pid, timeout: Self.postSignalWaitSeconds)
                    } else {
                        processExited = !signaler.isRunning(pid: candidate.pid)
                        canEscalateSignals = false
                    }
                }
            } else {
                gracefulAction = graceful?.label
            }

            let stillRunning: Bool
            if options.dryRun {
                stillRunning = signaler.isRunning(pid: candidate.pid)
            } else if processExited {
                stillRunning = false
            } else {
                stillRunning = try isOriginalProcessStillRunning(
                    matching: candidate,
                    workspaceHandle: workspaceHandle,
                    tolerateMissingRevalidation: attemptedShutdown
                )
            }

            return MemoryTrimResult(
                workspaceId: workspaceId,
                workspaceRef: workspaceRef,
                agent: candidate,
                gracefulAction: gracefulAction,
                attemptedShutdown: attemptedShutdown,
                terminated: terminated,
                killed: killed,
                stillRunning: stillRunning,
                dryRun: options.dryRun
            )
        }

        private func revalidatedSignalCandidate(
            matching original: MemoryAgentCandidate,
            workspaceHandle: String
        ) throws -> MemoryAgentCandidate? {
            guard signaler.isRunning(pid: original.pid) else { return nil }
            guard original.identity != nil else {
                throw CLIError(message: String(
                    format: String(
                        localized: "cli.memory.error.trimIdentityUnavailable",
                        defaultValue: "memory trim refused to signal PID %@ because the process identity was not available"
                    ),
                    String(original.pid)
                ))
            }

            let payload = try cli.buildMemoryTopPayload(workspaceHandle: workspaceHandle, client: client)
            guard let workspace = parser.workspaceNode(from: payload, matching: workspaceHandle),
                  let candidate = parser.candidates(in: workspace).first(where: { parser.matchesOriginal($0, original: original) }) else {
                guard signaler.isRunning(pid: original.pid) else { return nil }
                throw CLIError(message: String(
                    format: String(
                        localized: "cli.memory.error.trimIdentityUnverified",
                        defaultValue: "memory trim refused to signal PID %@ because the process identity could not be verified"
                    ),
                    String(original.pid)
                ))
            }
            return candidate
        }

        private func revalidatedSignalCandidate(
            matching original: MemoryAgentCandidate,
            workspaceHandle: String,
            tolerateMissingRevalidation: Bool
        ) throws -> MemoryAgentCandidate? {
            do {
                return try revalidatedSignalCandidate(matching: original, workspaceHandle: workspaceHandle)
            } catch {
                if tolerateMissingRevalidation {
                    return nil
                }
                throw error
            }
        }

        private func isOriginalProcessStillRunning(
            matching original: MemoryAgentCandidate,
            workspaceHandle: String,
            tolerateMissingRevalidation: Bool
        ) throws -> Bool {
            guard signaler.isRunning(pid: original.pid) else { return false }
            guard original.identity != nil else {
                return signaler.isRunning(pid: original.pid)
            }
            do {
                return try revalidatedSignalCandidate(matching: original, workspaceHandle: workspaceHandle) != nil
            } catch {
                if tolerateMissingRevalidation {
                    return signaler.isRunning(pid: original.pid)
                }
                throw error
            }
        }
    }
}
