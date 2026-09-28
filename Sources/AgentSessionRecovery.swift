import AppKit
import CMUXAgentLaunch
import CmuxAgentJournal
import CmuxFoundation
import Foundation

/// Recovers agent sessions that were running when cmux died.
///
/// The agent journal knows which sessions never ended, and the hook session
/// stores know where each ran and how it was launched. When the app comes back
/// after an unclean exit, the sessions that are neither running nor already
/// restored into a panel are reopened, one workspace each. Each resumes
/// through `cmux restore <kind> <id>`, the verb a normal restore types, from
/// a panel that carries the session's restore record. A session started
/// through an undeclared launcher that `cmux restore` cannot rebuild resumes
/// through that launcher instead (see `AgentLauncherPrefix`).
///
/// Only Claude is recovered: its `SessionEnd` hook marks sessions that ended
/// normally, so a session without one was killed. Codex has no end hook, so
/// every finished Codex session would look killed.
struct AgentSessionRecovery: Sendable {
    /// Kinds whose journal records a session end.
    static let recoverableKinds: [RestorableAgentKind] = [.claude]

    let journalURL: URL?
    let homeDirectory: String
    let environment: [String: String]

    init(
        journalURL: URL? = AgentJournalLifecycleCenter.defaultDatabaseURL(),
        homeDirectory: String = NSHomeDirectory(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.journalURL = journalURL
        self.homeDirectory = homeDirectory
        self.environment = environment
    }

    /// Reads the journal and hook stores. Does file and SQLite I/O; call it
    /// off the main thread.
    ///
    /// - Parameters:
    ///   - openSessionIds: Sessions already carried by open panels.
    ///   - activeSince: Start of the run that died; only sessions active
    ///     since then are considered. Nil falls back to the planner's limit.
    ///   - now: The current time.
    func candidates(
        openSessionIds: Set<String>,
        activeSince: Date? = nil,
        now: Date = Date()
    ) -> [AgentRecoveryCandidate] {
        let planner = AgentSessionRecoveryPlanner()
        let oldest = now.addingTimeInterval(-planner.maximumAge)
        return planner.candidates(
            journal: journalSessions(since: max(activeSince ?? oldest, oldest)),
            records: launchRecords(),
            openSessionIds: openSessionIds,
            isProcessAlive: Self.isProcessAlive,
            now: now
        )
    }

    private func journalSessions(since: Date) -> [AgentRecoveryJournalSession] {
        guard let journalURL, FileManager.default.fileExists(atPath: journalURL.path) else { return [] }
        let sinceMs = Int64(since.timeIntervalSince1970 * 1000)
        let tails = (try? AgentJournalSessionTailReader(databaseURL: journalURL)
            .sessionTails(occurredAtOrAfterMs: sinceMs)) ?? []
        return tails.map {
            AgentRecoveryJournalSession(
                sessionId: $0.sessionId,
                source: $0.source,
                lastOccurredAt: Date(timeIntervalSince1970: TimeInterval($0.lastOccurredAtMs) / 1000),
                hasEnded: $0.hasEnded
            )
        }
    }

    private func launchRecords() -> [AgentRecoveryLaunchRecord] {
        let decoder = JSONDecoder()
        return Self.recoverableKinds.flatMap { kind -> [AgentRecoveryLaunchRecord] in
            let url = kind.hookStoreFileURL(homeDirectory: homeDirectory, environment: environment)
            guard let data = try? Data(contentsOf: url),
                  let state = try? decoder.decode(RestorableAgentHookSessionStoreFile.self, from: data) else {
                return []
            }
            return state.sessions.values.compactMap { record in
                guard record.isRestorable != false,
                      record.launchCommand?.source?.lowercased() != "rejected",
                      Self.transcriptExists(record) else { return nil }
                return AgentRecoveryLaunchRecord(
                    kind: kind.rawValue,
                    sessionId: record.sessionId,
                    workspaceId: record.workspaceId,
                    cwd: record.cwd,
                    launchCommand: Self.trustedLaunchCommand(record.launchCommand, kind: kind),
                    pid: record.pid,
                    pidStartSeconds: record.pidStartSeconds,
                    permissionMode: record.lastPermissionMode,
                    updatedAt: Date(timeIntervalSince1970: record.updatedAt)
                )
            }
        }
    }

    /// Resume needs the transcript; a record without one on disk cannot resume.
    private static func transcriptExists(_ record: RestorableAgentHookSessionRecord) -> Bool {
        guard let path = record.transcriptPath, !path.isEmpty else { return false }
        return FileManager.default.fileExists(atPath: path)
    }

    /// Drops a launch capture inherited from another agent or the hook shell,
    /// matching the session index's admission rule.
    private static func trustedLaunchCommand(
        _ launchCommand: AgentLaunchCommand?,
        kind: RestorableAgentKind
    ) -> AgentLaunchCommand? {
        guard let launchCommand,
              AgentLaunchCaptureTrust.launcherDescribesKind(launchCommand.launcher, kind: kind.rawValue),
              !AgentLaunchCaptureTrust.argvLooksLikeShellWrapper(launchCommand.arguments) else {
            return nil
        }
        return launchCommand
    }

    private static func isProcessAlive(pid: Int, startSeconds: Int64?) -> Bool {
        guard pid > 0, let identity = AgentPIDProcessIdentity(pid: pid_t(pid)) else { return false }
        guard let startSeconds else { return false }
        return identity.startSeconds == startSeconds
    }

    /// How a recovered session starts in its new terminal.
    enum Launch {
        /// Type the `cmux restore` verb into a panel carrying `agent` as its
        /// restore record, so the session resumes exactly as a normal restore
        /// would (routed launcher, wrapper authorization, permission mode).
        case restoreVerb(input: String, agent: SessionRestorableAgentSnapshot)
        /// Type a shell command that resumes through an undeclared launcher
        /// the restore verb has no record of.
        case launcherCommand(String)

        /// Text typed into the new terminal, including its trailing newline.
        var terminalInput: String {
            switch self {
            case .restoreVerb(let input, _): input
            case .launcherCommand(let command): command + "\n"
            }
        }
    }

    /// The restorable-agent snapshot `cmux restore` reads for `candidate`.
    static func restorableAgent(for candidate: AgentRecoveryCandidate) -> SessionRestorableAgentSnapshot? {
        guard let kind = RestorableAgentKind(rawValue: candidate.kind),
              kind.restoreMode == .resumeSession else { return nil }
        return SessionRestorableAgentSnapshot(
            kind: kind,
            sessionId: candidate.sessionId,
            workingDirectory: candidate.cwd,
            launchCommand: candidate.launchCommand,
            permissionMode: candidate.permissionMode
        )
    }

    /// How `candidate` resumes: through its recorded launcher when only that
    /// launcher can rebuild it, otherwise through `cmux restore`.
    static func launch(for candidate: AgentRecoveryCandidate) -> Launch? {
        guard let agent = restorableAgent(for: candidate) else { return nil }
        if let arguments = candidate.launcherResumeArguments {
            return AgentResumeCommandBuilder.launcherResumeShellCommand(
                kind: agent.kind,
                sessionId: candidate.sessionId,
                launchCommand: candidate.launchCommand,
                launcherArguments: arguments
            ).map(Launch.launcherCommand)
        }
        return agent.resumeStartupInput(useLocalRestoreVerb: true).map {
            .restoreVerb(input: $0, agent: agent)
        }
    }

    /// The command shown for `candidate` in `session.agent_recovery.*` results.
    static func resumeCommand(for candidate: AgentRecoveryCandidate) -> String? {
        launch(for: candidate)?.terminalInput.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Workspace title for a recovered session: the cwd's last component.
    static func workspaceTitle(for candidate: AgentRecoveryCandidate) -> String {
        guard let cwd = candidate.cwd, !cwd.isEmpty else { return candidate.kind }
        let name = URL(fileURLWithPath: cwd).lastPathComponent
        return name.isEmpty ? cwd : name
    }
}

extension AppDelegate {
    /// Agent session ids already carried by open panels (restored from the
    /// snapshot or bound since launch), which recovery must not duplicate.
    ///
    /// Covers workspace panels, workspace and window Docks, and restores that
    /// are staged or deferred but have not launched yet. Entries for
    /// `excludedPanelId` are skipped.
    func openAgentSessionIdsForRecovery(excludingPanelId excludedPanelId: UUID? = nil) -> Set<String> {
        var managers = mainWindowContexts.values.map(\.tabManager)
        if let tabManager, !managers.contains(where: { $0 === tabManager }) {
            managers.append(tabManager)
        }
        var ids = Set<String>()
        func collect(
            restored: [UUID: SessionRestorableAgentSnapshot],
            bindings: [UUID: SurfaceResumeBindingSnapshot],
            deferred: [UUID: DeferredAgentResumeRestore]
        ) {
            ids.formUnion(restored.filter { $0.key != excludedPanelId }.values.map(\.sessionId))
            ids.formUnion(bindings.filter { $0.key != excludedPanelId }.values.compactMap(\.checkpointId))
            for (panelId, restore) in deferred where panelId != excludedPanelId {
                if let sessionId = restore.restorableAgent?.sessionId { ids.insert(sessionId) }
                if let checkpointId = restore.resumeBinding?.checkpointId { ids.insert(checkpointId) }
            }
        }
        func collect(_ dock: DockSplitStore) {
            collect(
                restored: dock.restoredAgentLifecycle.snapshotsByPanelId,
                bindings: dock.surfaceResumeBindingsByPanelId,
                deferred: dock.deferredAgentResumeRestoresByPanelId
            )
        }
        for manager in managers {
            for workspace in manager.tabs {
                collect(
                    restored: workspace.restoredAgentSnapshotsByPanelId,
                    bindings: workspace.surfaceResumeBindingsByPanelId,
                    deferred: workspace.deferredAgentResumeRestoresByPanelId
                )
                if let dock = workspace._dockSplit { collect(dock) }
            }
        }
        for dock in existingWindowDocks { collect(dock) }
        return ids
    }

    /// Reopens each candidate in its own workspace and types its resume
    /// command. Returns the session ids that were started.
    @discardableResult
    func restoreRecoveredAgentSessions(_ candidates: [AgentRecoveryCandidate]) -> [String] {
        guard let tabManager else { return [] }
        let alreadyOpen = openAgentSessionIdsForRecovery()
        var restored: [String] = []
        for candidate in candidates where !alreadyOpen.contains(candidate.sessionId) {
            guard let launch = AgentSessionRecovery.launch(for: candidate) else { continue }
            let directory = candidate.cwd.flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil }
            let startupAgent: SessionRestorableAgentSnapshot?
            switch launch {
            case .restoreVerb(_, let agent):
                // `cmux restore` takes the launch claim at its admission
                // boundary, so a concurrent restore cannot start the session
                // twice. The panel carries the session, so a second recovery
                // sees it as open.
                startupAgent = agent
            case .launcherCommand:
                // Nothing downstream claims a launcher command; take the
                // claim startup restore takes before typing it.
                guard AgentResumeLaunchGuard.shared.claimResumeLaunch(
                    kind: candidate.kind,
                    sessionId: candidate.sessionId
                ) else { continue }
                startupAgent = nil
            }
            guard tabManager.addWorkspaceIfActive(
                title: AgentSessionRecovery.workspaceTitle(for: candidate),
                titleSource: .auto,
                workingDirectory: directory,
                initialTerminalInput: launch.terminalInput,
                initialTerminalStartupRestoreAgent: startupAgent,
                select: false,
                // Start the terminal now so the agent is running (and its
                // hook record carries a live pid) without waiting for a visit;
                // a launcher command's claim would otherwise expire first.
                eagerLoadTerminal: true
            ) != nil else {
                if startupAgent == nil {
                    AgentResumeLaunchGuard.shared.releaseResumeLaunch(kind: candidate.kind, sessionId: candidate.sessionId)
                }
                continue
            }
            restored.append(candidate.sessionId)
        }
        return restored
    }

    /// After a launch that followed an unclean exit, finds agent sessions the
    /// snapshot did not bring back. With `terminal.autoResumeAgentSessions`
    /// on they are reopened automatically; otherwise the user is offered a
    /// one-click restore.
    func scheduleAgentSessionRecoveryAfterUncleanLaunchIfNeeded() {
        guard previousLaunchWasUncleanForRecovery,
              !didScheduleAgentSessionRecovery,
              SessionRestorePolicy.shouldAttemptRestore(),
              !SessionRestorePolicy.isRunningUnderAutomatedTests() else { return }
        didScheduleAgentSessionRecovery = true
        // Runs once session restore has completed: restored panels, including
        // staged and deferred agent resumes, are already visible to the open-id
        // scan, and restoreRecoveredAgentSessions repeats it before launching.
        // Without the dead run's start time the window would widen to the
        // planner's 48-hour limit and pull in sessions from earlier runs that
        // exited cleanly; those stay reachable through `cmux session restore
        // --session <id>`.
        guard let activeSince = previousSessionLaunchStartedAt else { return }
        let openSessionIds = openAgentSessionIdsForRecovery()
        let recovery = AgentSessionRecovery()
        Task.detached(priority: .utility) {
            let candidates = recovery.candidates(openSessionIds: openSessionIds, activeSince: activeSince)
            guard !candidates.isEmpty else { return }
            await MainActor.run { [weak self] in
                self?.offerAgentSessionRecovery(candidates)
            }
        }
    }

    private func offerAgentSessionRecovery(_ candidates: [AgentRecoveryCandidate]) {
        guard !isTerminatingApp else { return }
        if AgentSessionAutoResumeSettings.isEnabled() {
            restoreRecoveredAgentSessions(candidates)
            return
        }
        let alert = NSAlert()
        alert.messageText = String(
            localized: "agentRecovery.alert.title",
            defaultValue: "Restore agent sessions?"
        )
        alert.informativeText = String(
            localized: "agentRecovery.alert.message",
            defaultValue: "cmux quit unexpectedly while agent sessions were running. Sessions to restore: \(candidates.count). Each one reopens in its own workspace and resumes where it left off."
        )
        alert.addButton(withTitle: String(
            localized: "agentRecovery.alert.restore",
            defaultValue: "Restore Agent Sessions"
        ))
        alert.addButton(withTitle: String(localized: "agentRecovery.alert.notNow", defaultValue: "Not Now"))
        if alert.runModal() == .alertFirstButtonReturn {
            restoreRecoveredAgentSessions(candidates)
        }
    }
}

extension TerminalController {
    /// `session.agent_recovery.list`: agent sessions that were running when
    /// cmux last died and are neither running nor open now. After a clean
    /// exit nothing was lost, so the wider 48-hour window is listed for
    /// inspection only. Runs on the socket worker; only the app-state reads
    /// hop to the main actor.
    nonisolated func v2AgentRecoveryList(params: [String: Any]) -> V2CallResult {
        guard let context = v2MainSync(commandKey: "session.agent_recovery.list", { Self.agentRecoveryContext() }) else {
            return .err(code: "unavailable", message: "App is not ready", data: nil)
        }
        let candidates = context.recovery.candidates(
            openSessionIds: context.openSessionIds,
            activeSince: context.activeSince
        )
        return .ok([
            "sessions": candidates.map(Self.agentRecoveryPayload),
            "previous_exit_unclean": context.previousExitUnclean,
        ])
    }

    /// `session.agent_recovery.restore`: reopens those sessions, or only the
    /// ones named in `session_ids`, one workspace each. After a clean exit a
    /// session without an end event is more likely a closed pane than a lost
    /// one, so only named sessions are restored then.
    nonisolated func v2AgentRecoveryRestore(params: [String: Any]) -> V2CallResult {
        let requestedSessionIDs: [String]?
        if let rawRequestedSessionIDs = params["session_ids"] {
            guard let requested = rawRequestedSessionIDs as? [String], !requested.isEmpty else {
                return .err(
                    code: "invalid_params",
                    message: String(
                        format: String(
                            localized: "socket.surfaceSelection.invalidSelector",
                            defaultValue: "Invalid selector for `%@`."
                        ),
                        "session_ids"
                    ),
                    data: nil
                )
            }
            requestedSessionIDs = requested
        } else {
            requestedSessionIDs = nil
        }
        guard let context = v2MainSync(commandKey: "session.agent_recovery.restore", { Self.agentRecoveryContext() }) else {
            return .err(code: "unavailable", message: "App is not ready", data: nil)
        }
        var candidates = context.recovery.candidates(
            openSessionIds: context.openSessionIds,
            activeSince: context.activeSince
        )
        if let requested = requestedSessionIDs {
            let wanted = Set(requested)
            candidates = candidates.filter { wanted.contains($0.sessionId) }
        } else if !context.previousExitUnclean || context.activeSince == nil {
            // Unnamed restore acts only on sessions from the run that died.
            candidates = []
        }
        let selected = candidates
        let restored = Set(v2MainSync(commandKey: "session.agent_recovery.restore") {
            AppDelegate.shared?.restoreRecoveredAgentSessions(selected) ?? []
        })
        return .ok([
            "restored": selected.filter { restored.contains($0.sessionId) }.map(Self.agentRecoveryPayload),
            "previous_exit_unclean": context.previousExitUnclean,
        ])
    }

    private struct AgentRecoveryContext: Sendable {
        let recovery: AgentSessionRecovery
        let openSessionIds: Set<String>
        let activeSince: Date?
        let previousExitUnclean: Bool
    }

    @MainActor
    private static func agentRecoveryContext() -> AgentRecoveryContext? {
        guard let appDelegate = AppDelegate.shared else { return nil }
        return AgentRecoveryContext(
            recovery: AgentSessionRecovery(),
            openSessionIds: appDelegate.openAgentSessionIdsForRecovery(),
            activeSince: appDelegate.previousSessionLaunchStartedAt,
            previousExitUnclean: appDelegate.previousLaunchWasUncleanForRecovery
        )
    }

    private nonisolated static func agentRecoveryPayload(_ candidate: AgentRecoveryCandidate) -> [String: Any] {
        [
            "kind": candidate.kind,
            "session_id": candidate.sessionId,
            "cwd": candidate.cwd ?? NSNull(),
            "workspace_id": candidate.workspaceId ?? NSNull(),
            "last_activity": candidate.lastActivity.timeIntervalSince1970,
            "command": AgentSessionRecovery.resumeCommand(for: candidate) ?? NSNull(),
        ]
    }
}
