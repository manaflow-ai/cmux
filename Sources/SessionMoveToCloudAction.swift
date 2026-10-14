import CmuxCloud
import CmuxSettings
import CmuxSidebar
import Foundation

/// Starts the bundled `cmux session move` for an app entrypoint and reports how
/// it ended. A protocol so tests can stand in for the child process.
@MainActor
protocol SessionMoveCLILaunching: AnyObject {
    /// False when the CLI could not start; `onCompletion` then never runs.
    /// `terminationStatus` is the CLI's exit status; a cancelled run reports
    /// a non-zero status.
    func launchSessionMove(
        arguments: [String],
        workingDirectory: URL?,
        onOutput: @escaping @MainActor (String) -> Void,
        onCompletion: @escaping @MainActor (_ terminationStatus: Int32, _ output: String) -> Void
    ) -> Bool
}

/// Stops Claude at a turn boundary before its session leaves this Mac, and
/// starts it again in place when the move fails.
@MainActor
protocol SessionMoveAgentStopping: AnyObject {
    func stopAgent(workspaceId: UUID, panelId: UUID) async -> AgentHibernationManualRefusal?
    func resumeAgent(workspaceId: UUID, panelId: UUID)
    /// Ends the stopped agent here for good once its session lives on the
    /// machine, so neither this run nor a relaunch resumes it on this Mac.
    func endMovedAgent(workspaceId: UUID, panelId: UUID)
}

/// Move to Cloud: the one path behind the workspace row menu, the terminal
/// context menu and the command palette.
///
/// It stops Claude through the protected hibernation teardown (the pane may be
/// on screen; every other safety check still applies), then runs
/// `cmux session move <id> --to cloud[:<machine>]` from the session's cwd. The
/// pane holds its wake from the stop on: a failed move resumes Claude in place,
/// a finished one ends it here for good because the session now runs on the
/// machine, and keeps the hold.
@MainActor
final class SessionMoveToCloudAction {
    static var shared = SessionMoveToCloudAction()
    static let statusKey = "cloud.move"
    /// `cmux session move` exits with this status when the session already
    /// reached the machine but a later step, such as opening its Cloud
    /// terminal, failed. The conversation is no longer this Mac's to resume.
    static let movedWithoutTerminalExitStatus: Int32 = 3
    /// Panes whose Claude was stopped for a move; they must not wake again here.
    private static var resumeHeldPanelIds: Set<UUID> = []

    private let launcher: any SessionMoveCLILaunching
    private let stopper: any SessionMoveAgentStopping
    private let resolveSnapshot: @MainActor (Workspace, UUID) -> SessionRestorableAgentSnapshot?
    private let isCloudEnabled: @MainActor () -> Bool
    private let notifyFailure: @MainActor (_ workspaceId: UUID, _ body: String) -> Void
    private let notifyMovedWithoutTerminal: @MainActor (_ workspaceId: UUID, _ body: String) -> Void
    /// Lower-cased ids of sessions with a move running; a second click is a no-op.
    private var inFlightSessionIds: Set<String> = []
    /// The newest refusal shown per pane, so an older one's timer never clears it.
    private var refusalTokens: [UUID: UUID] = [:]

    init(
        launcher: (any SessionMoveCLILaunching)? = nil,
        stopper: (any SessionMoveAgentStopping)? = nil,
        resolveSnapshot: (@MainActor (Workspace, UUID) -> SessionRestorableAgentSnapshot?)? = nil,
        isCloudEnabled: (@MainActor () -> Bool)? = nil,
        notifyFailure: (@MainActor (_ workspaceId: UUID, _ body: String) -> Void)? = nil,
        notifyMovedWithoutTerminal: (@MainActor (_ workspaceId: UUID, _ body: String) -> Void)? = nil
    ) {
        self.launcher = launcher ?? CloudVMSessionMoveLauncher()
        self.stopper = stopper ?? AgentHibernationSessionMoveStopper()
        self.resolveSnapshot = resolveSnapshot ?? { workspace, panelId in Self.liveSnapshot(workspace: workspace, panelId: panelId) }
        self.isCloudEnabled = isCloudEnabled ?? { CloudMachinesFeature.isEnabled }
        self.notifyFailure = notifyFailure ?? { workspaceId, body in Self.postFailureNotification(workspaceId: workspaceId, body: body) }
        self.notifyMovedWithoutTerminal = notifyMovedWithoutTerminal ?? { workspaceId, body in
            Self.postNotification(
                workspaceId: workspaceId,
                title: String(localized: "cloudMove.movedWithoutTerminal.title", defaultValue: "Moved to Cloud"),
                body: body
            )
        }
    }

    static func holdsAgentResume(panelId: UUID) -> Bool {
        resumeHeldPanelIds.contains(panelId)
    }

    /// The Claude session a move would carry, or nil when the pane is not a
    /// local terminal running Claude, its session is moving or has moved, or
    /// Cloud is off.
    func canMove(workspace: Workspace, panelId: UUID) -> SessionRestorableAgentSnapshot? {
        guard isCloudEnabled(),
              !Self.resumeHeldPanelIds.contains(panelId),
              !workspace.isRemoteWorkspace,
              workspace.cloudVMID == nil,
              workspace.panels[panelId] is TerminalPanel,
              !workspace.terminalRunsOnAnotherMachine(panelId),
              let snapshot = resolveSnapshot(workspace, panelId),
              snapshot.kind == .claude,
              !snapshot.sessionId.isEmpty else { return nil }
        return snapshot
    }

    /// The pane a workspace-level entrypoint moves: the focused terminal, else
    /// the workspace's only movable Claude.
    func movablePanelId(in workspace: Workspace) -> UUID? {
        if let focused = workspace.focusedPanelId, canMove(workspace: workspace, panelId: focused) != nil {
            return focused
        }
        let movable = workspace.panels.keys.filter { canMove(workspace: workspace, panelId: $0) != nil }
        return movable.count == 1 ? movable.first : nil
    }

    /// Starts the move; nil when the pane cannot move or its session is
    /// already moving. The task ends when the move does.
    @discardableResult
    func move(workspace: Workspace, panelId: UUID, machine: String?) -> Task<Void, Never>? {
        guard let snapshot = canMove(workspace: workspace, panelId: panelId),
              inFlightSessionIds.insert(snapshot.sessionId.lowercased()).inserted else { return nil }
        let workspaceId = workspace.id
        refusalTokens.removeValue(forKey: panelId)
        setStatus(
            String(localized: "cloudMove.status.stopping", defaultValue: "Stopping Claude to move it to Cloud…"),
            icon: "icloud.and.arrow.up", workspace: workspace, panelId: panelId
        )
        // Held before the stop commits: a pane on screen would wake Claude at once.
        // Only the call that placed the hold may release it.
        let placedHold = Self.resumeHeldPanelIds.insert(panelId).inserted
        return Task { [weak workspace] in
            let refusal = await self.stopper.stopAgent(workspaceId: workspaceId, panelId: panelId)
            // An agent hibernated earlier is already stopped; moving it is safe.
            if let refusal, refusal != .alreadyHibernated {
                self.inFlightSessionIds.remove(snapshot.sessionId.lowercased())
                if placedHold { Self.resumeHeldPanelIds.remove(panelId) }
                if let workspace { self.showRefusal(refusal, workspace: workspace, panelId: panelId) }
                return
            }
            let outcome = await self.runCLI(snapshot: snapshot, machine: machine, workspace: workspace, panelId: panelId)
            self.inFlightSessionIds.remove(snapshot.sessionId.lowercased())
            workspace?.clearStatusEntry(key: Self.statusKey, panelId: panelId)
            switch outcome?.terminationStatus {
            case .some(0):
                self.stopper.endMovedAgent(workspaceId: workspaceId, panelId: panelId)
            case .some(Self.movedWithoutTerminalExitStatus):
                // The session is on the machine: resuming here would make a
                // second writer, so end it here like a finished move.
                self.stopper.endMovedAgent(workspaceId: workspaceId, panelId: panelId)
                self.notifyMovedWithoutTerminal(workspaceId, Self.movedWithoutTerminalBody(output: outcome?.output ?? ""))
            default:
                if placedHold { Self.resumeHeldPanelIds.remove(panelId) }
                if refusal == nil { self.stopper.resumeAgent(workspaceId: workspaceId, panelId: panelId) }
                self.notifyFailure(workspaceId, Self.failureBody(output: outcome?.output ?? ""))
            }
        }
    }

    private struct CLIOutcome: Sendable {
        let terminationStatus: Int32
        let output: String
    }

    private func runCLI(
        snapshot: SessionRestorableAgentSnapshot,
        machine: String?,
        workspace: Workspace?,
        panelId: UUID
    ) async -> CLIOutcome? {
        if let workspace {
            setStatus(
                String(localized: "cloudMove.status.moving", defaultValue: "Moving to Cloud…"),
                icon: "icloud.and.arrow.up", workspace: workspace, panelId: panelId
            )
        }
        let destination = machine.map { "cloud:" + $0 } ?? "cloud"
        let arguments = ["session", "move", snapshot.sessionId, "--to", destination, "--no-focus"]
        let workingDirectory = Self.existingDirectory(snapshot.workingDirectory ?? snapshot.launchCommand?.workingDirectory)
        return await withCheckedContinuation { continuation in
            let launched = launcher.launchSessionMove(
                arguments: arguments,
                workingDirectory: workingDirectory,
                onOutput: { [weak self, weak workspace] chunk in
                    guard let self, let workspace, let line = Self.lastSafeLine(of: chunk) else { return }
                    let format = String(localized: "cloudMove.status.progress", defaultValue: "Moving to Cloud: %@")
                    self.setStatus(String(format: format, line), icon: "icloud.and.arrow.up", workspace: workspace, panelId: panelId)
                },
                onCompletion: { terminationStatus, output in
                    continuation.resume(returning: CLIOutcome(terminationStatus: terminationStatus, output: output))
                }
            )
            if !launched { continuation.resume(returning: nil) }
        }
    }

    private func setStatus(_ value: String, icon: String, workspace: Workspace, panelId: UUID) {
        workspace.setStatusEntry(
            SidebarStatusEntry(key: Self.statusKey, value: value, icon: icon),
            key: Self.statusKey,
            panelId: panelId
        )
    }

    /// Shows why Claude was left running next to the workspace, for a few seconds.
    private func showRefusal(_ refusal: AgentHibernationManualRefusal, workspace: Workspace, panelId: UUID) {
        let format = String(localized: "cloudMove.status.refused", defaultValue: "Not moved to Cloud: %@")
        setStatus(String(format: format, Self.refusalMessage(refusal)), icon: "exclamationmark.icloud", workspace: workspace, panelId: panelId)
        let token = UUID()
        refusalTokens[panelId] = token
        Task { [weak self, weak workspace] in
            try? await Task.sleep(for: .seconds(8))
            guard let self, self.refusalTokens[panelId] == token else { return }
            self.refusalTokens.removeValue(forKey: panelId)
            workspace?.clearStatusEntry(key: Self.statusKey, panelId: panelId)
        }
    }

    static func refusalMessage(_ refusal: AgentHibernationManualRefusal) -> String {
        switch refusal {
        case .agentBusy:
            String(localized: "cloudMove.refusal.agentBusy", defaultValue: "Claude is working or waiting for input. Move it when the turn ends.")
        case .recentlyActive:
            String(localized: "cloudMove.refusal.recentlyActive", defaultValue: "Claude was active a moment ago. Try again in a few seconds.")
        case .unconfirmedInput:
            String(localized: "cloudMove.refusal.unconfirmedInput", defaultValue: "Claude has typed input it has not received yet.")
        case .lifecycleUnknown:
            String(localized: "cloudMove.refusal.lifecycleUnknown", defaultValue: "cmux can't tell whether Claude is idle.")
        case .processScopeUnsafe:
            String(localized: "cloudMove.refusal.processScopeUnsafe", defaultValue: "This terminal is running other work, such as background jobs, that the move would stop.")
        case .surfaceNotFound, .notRestorable, .alreadyHibernated, .notRunning, .visible, .teardownInProgress, .teardownRefused:
            String(localized: "cloudMove.refusal.generic", defaultValue: "Claude could not be stopped safely. Try again in a moment.")
        }
    }

    /// The CLI's reason, from the last output line the Cloud redaction lets through.
    static func failureBody(output: String) -> String {
        lastSafeLine(of: output) ?? String(
            localized: "cloudMove.failed.generic",
            defaultValue: "The move did not finish and the conversation stays on this Mac. Run cmux session move in a terminal to see the full output."
        )
    }

    /// The CLI's own account of the half-finished move, when it is safe to show.
    static func movedWithoutTerminalBody(output: String) -> String {
        lastSafeLine(of: output) ?? String(
            localized: "cloudMove.movedWithoutTerminal.generic",
            defaultValue: "The conversation is on the Cloud machine now, but its terminal didn't open."
        )
    }

    private static func lastSafeLine(of output: String) -> String? {
        output.split(whereSeparator: \.isNewline).reversed().lazy
            .compactMap { CloudVMActionLauncher.firstSafeLine(of: String($0)) }
            .first
    }

    private static func existingDirectory(_ path: String?) -> URL? {
        guard let path, !path.isEmpty else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// The live agent index first, then the restored snapshot: the sources
    /// Fork Conversation reads, without its fork-support probe.
    private static func liveSnapshot(workspace: Workspace, panelId: UUID) -> SessionRestorableAgentSnapshot? {
        guard workspace.allowsAgentContinuation(forPanelId: panelId) else { return nil }
        return SharedLiveAgentIndex.shared.snapshot(workspaceId: workspace.id, panelId: panelId)
            ?? workspace.restoredAgentSnapshotForContinuation(panelId: panelId)
    }

    private static func postFailureNotification(workspaceId: UUID, body: String) {
        postNotification(
            workspaceId: workspaceId,
            title: String(localized: "cloudMove.failed.title", defaultValue: "Couldn't Move to Cloud"),
            body: body
        )
    }

    /// Follows ``MachineCreateNotifier``: anchored to the workspace while it exists.
    private static func postNotification(workspaceId: UUID, title: String, body: String) {
        guard let appDelegate = AppDelegate.shared else { return }
        let anchorTabID = appDelegate.tabManagerFor(tabId: workspaceId) != nil
            ? workspaceId
            : appDelegate.activeTabManagerForCommands(preferredWindow: nil)?.selectedTabId
        guard let anchorTabID else { return }
        TerminalNotificationStore.shared.addNotification(
            tabId: anchorTabID,
            surfaceId: nil,
            title: title,
            subtitle: "",
            body: body,
            retargetsToLiveSurfaceOwner: false
        )
    }
}

/// Runs the move through the same launcher as every other Cloud verb, without
/// its failure alert: the action reports failures as a notification.
@MainActor
final class CloudVMSessionMoveLauncher: SessionMoveCLILaunching {
    func launchSessionMove(
        arguments: [String],
        workingDirectory: URL?,
        onOutput: @escaping @MainActor (String) -> Void,
        onCompletion: @escaping @MainActor (Int32, String) -> Void
    ) -> Bool {
        CloudVMActionLauncher.shared.start(
            socketPath: TerminalController.shared.activeSocketPath(preferredPath: SocketControlSettings.socketPath()),
            preferredWindow: nil,
            arguments: arguments,
            presentsFailureAlert: false,
            workingDirectory: workingDirectory,
            onOutput: onOutput,
            onCompletion: { completion in
                onCompletion(completion.wasCancelled ? -1 : completion.terminationStatus, completion.output)
            }
        )
    }
}

/// Stops Claude through ``AgentHibernationController/hibernateNow`` with the
/// session-move trigger, wakes it through `cmux agent wake`'s path, and ends
/// it through ``Workspace/endAgentHibernationAfterSessionMove(panelId:)``.
@MainActor
final class AgentHibernationSessionMoveStopper: SessionMoveAgentStopping {
    func stopAgent(workspaceId: UUID, panelId: UUID) async -> AgentHibernationManualRefusal? {
        let index = await RestorableAgentSessionIndex.loadIncludingProcessDetectedSnapshots()
        return await AgentHibernationController.shared.hibernateNow(
            workspaceId: workspaceId,
            panelId: panelId,
            index: index,
            trigger: .sessionMove
        )
    }

    func resumeAgent(workspaceId: UUID, panelId: UUID) {
        _ = AgentHibernationController.shared.wakeNow(workspaceId: workspaceId, panelId: panelId)
    }

    func endMovedAgent(workspaceId: UUID, panelId: UUID) {
        AppDelegate.shared?
            .workspaceContainingPanel(panelId: panelId, preferredWorkspaceId: workspaceId)?
            .workspace
            .endAgentHibernationAfterSessionMove(panelId: panelId)
    }
}
