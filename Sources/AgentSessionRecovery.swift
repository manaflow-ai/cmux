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
/// restored into a panel are reopened, one workspace each, and resumed through
/// the launcher that originally started them (see `AgentLauncherPrefix`).
struct AgentSessionRecovery: Sendable {
    /// Kinds whose hook stores carry launch records recovery can resume.
    static let recoverableKinds: [RestorableAgentKind] = [.claude, .codex]

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
    func candidates(openSessionIds: Set<String>, now: Date = Date()) -> [AgentRecoveryCandidate] {
        let planner = AgentSessionRecoveryPlanner()
        return planner.candidates(
            journal: journalSessions(since: now.addingTimeInterval(-planner.maximumAge)),
            records: launchRecords(),
            openSessionIds: openSessionIds,
            isProcessAlive: Self.isProcessAlive,
            now: now
        )
    }

    private func journalSessions(since: Date) -> [AgentRecoveryJournalSession] {
        guard let journalURL, FileManager.default.fileExists(atPath: journalURL.path),
              let store = try? AgentJournalStore(databaseURL: journalURL) else { return [] }
        defer { store.close() }
        let sinceMs = Int64(since.timeIntervalSince1970 * 1000)
        let tails = (try? store.sessionTails(occurredAtOrAfterMs: sinceMs)) ?? []
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
                      record.launchCommand?.source?.lowercased() != "rejected" else { return nil }
                return AgentRecoveryLaunchRecord(
                    kind: kind.rawValue,
                    sessionId: record.sessionId,
                    workspaceId: record.workspaceId,
                    cwd: record.cwd,
                    launchCommand: record.launchCommand,
                    pid: record.pid,
                    pidStartSeconds: record.pidStartSeconds,
                    updatedAt: Date(timeIntervalSince1970: record.updatedAt)
                )
            }
        }
    }

    private static func isProcessAlive(pid: Int, startSeconds: Int64?) -> Bool {
        guard pid > 0, let identity = AgentPIDProcessIdentity(pid: pid_t(pid)) else { return false }
        guard let startSeconds else { return true }
        return identity.startSeconds == startSeconds
    }

    /// The shell input that resumes `candidate`: through its recorded
    /// launcher when there is one, otherwise the kind's normal resume command.
    static func resumeCommand(for candidate: AgentRecoveryCandidate) -> String? {
        if let arguments = candidate.launcherResumeArguments {
            return arguments.map(shellQuoted).joined(separator: " ")
        }
        return RestorableAgentKind(rawValue: candidate.kind)?.resumeCommand(
            sessionId: candidate.sessionId,
            launchCommand: candidate.launchCommand,
            workingDirectory: candidate.cwd
        )
    }

    static func shellQuoted(_ value: String) -> String {
        let plain = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789@%+=:,./_-")
        if !value.isEmpty, value.unicodeScalars.allSatisfy({ plain.contains($0) }) {
            return value
        }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
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
    func openAgentSessionIdsForRecovery() -> Set<String> {
        var managers = mainWindowContexts.values.map(\.tabManager)
        if let tabManager, !managers.contains(where: { $0 === tabManager }) {
            managers.append(tabManager)
        }
        var ids = Set<String>()
        for manager in managers {
            for workspace in manager.tabs {
                ids.formUnion(workspace.restoredAgentSnapshotsByPanelId.values.map(\.sessionId))
                ids.formUnion(workspace.surfaceResumeBindingsByPanelId.values.compactMap(\.checkpointId))
            }
        }
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
            guard let command = AgentSessionRecovery.resumeCommand(for: candidate) else { continue }
            let directory = candidate.cwd.flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil }
            _ = tabManager.addWorkspace(
                title: AgentSessionRecovery.workspaceTitle(for: candidate),
                workingDirectory: directory,
                initialTerminalInput: command + "\r",
                select: false
            )
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
              !SessionRestorePolicy.isRunningUnderAutomatedTests() else { return }
        didScheduleAgentSessionRecovery = true
        // Give restored panels a moment to claim their agents first.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, !self.isTerminatingApp else { return }
            let openSessionIds = self.openAgentSessionIdsForRecovery()
            let recovery = AgentSessionRecovery()
            Task.detached(priority: .utility) {
                let candidates = recovery.candidates(openSessionIds: openSessionIds)
                guard !candidates.isEmpty else { return }
                await MainActor.run { [weak self] in
                    self?.offerAgentSessionRecovery(candidates)
                }
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
    /// cmux last died and are neither running nor open now.
    func v2AgentRecoveryList(params: [String: Any]) -> V2CallResult {
        let openSessionIds = AppDelegate.shared?.openAgentSessionIdsForRecovery() ?? []
        let candidates = AgentSessionRecovery().candidates(openSessionIds: openSessionIds)
        return .ok(["sessions": candidates.map(Self.agentRecoveryPayload)])
    }

    /// `session.agent_recovery.restore`: reopens those sessions, or only the
    /// ones named in `session_ids`, one workspace each.
    func v2AgentRecoveryRestore(params: [String: Any]) -> V2CallResult {
        guard let appDelegate = AppDelegate.shared else {
            return .err(code: "unavailable", message: "App is not ready", data: nil)
        }
        var candidates = AgentSessionRecovery().candidates(
            openSessionIds: appDelegate.openAgentSessionIdsForRecovery()
        )
        if let requested = params["session_ids"] as? [String], !requested.isEmpty {
            let wanted = Set(requested)
            candidates = candidates.filter { wanted.contains($0.sessionId) }
        }
        let restored = Set(appDelegate.restoreRecoveredAgentSessions(candidates))
        return .ok([
            "restored": candidates.filter { restored.contains($0.sessionId) }.map(Self.agentRecoveryPayload),
        ])
    }

    private static func agentRecoveryPayload(_ candidate: AgentRecoveryCandidate) -> [String: Any] {
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
