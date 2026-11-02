import CmuxNextAgentPane
import CmuxNextBridge
import CmuxNextCompat
import CmuxNextDaemon
import CmuxNextDaemonService
import CmuxNextOnboarding
import CmuxNextSidebar
import CmuxNextWakeups
import Foundation

/// What `workspace.importClassic` opened and what it left in classic.
struct ClassicImportSummary: Equatable {
    var opened = 0
    /// Cloud VM workspaces: cmux-next cannot reach a classic VM.
    var leftCloudVMs = false
    /// SSH workspaces whose host did not connect.
    var leftSSH = false
    /// Scrollback of SSH terminals: their shells run on the host, where this
    /// Mac's replay file is not.
    var leftSSHScrollback = false
    /// Markdown and file preview tabs: nothing here shows them.
    var leftTabs = false
    /// Classic workspaces an earlier run brought over that are still open here.
    var alreadyHere = 0

    /// Adds what `other` (one workspace's import) opened and left.
    mutating func merge(_ other: ClassicImportSummary) {
        opened += other.opened
        leftCloudVMs = leftCloudVMs || other.leftCloudVMs
        leftSSH = leftSSH || other.leftSSH
        leftSSHScrollback = leftSSHScrollback || other.leftSSHScrollback
        leftTabs = leftTabs || other.leftTabs
        alreadyHere += other.alreadyHere
    }
}

/// Classic cmux session import (Leo, cx-aha.5): one workspace at a time, for
/// `workspace.importClassic` (cx-rwlb, cx-1uacm) and for the one-time
/// migration at launch (`AppOnboardingServices+ClassicMigration.swift`).
extension AppOnboardingServices {

    /// Runs Import Workspaces from Classic cmux: every classic workspace not
    /// already open here (the migration ledger knows which ones came over),
    /// with its window, group, color and pin. `progress` hears the share of classic workspaces
    /// handled, 0...1. See ``migrateClassic(_:firstWorkspace:confirmation:progress:)``.
    func importClassicSessions(progress: (@MainActor (Double) -> Void)? = nil) async throws -> ClassicImportSummary? {
        let outcome = try await migrateClassic(.manual, confirmation: confirmClassicImport, progress: progress)
        return outcome.confirmed ? outcome.summary : nil
    }

    /// Opens one classic workspace here: a local or SSH workspace with its
    /// splits, terminal tabs in their folders, browser tabs on their pages,
    /// agent sessions as chats resuming them, and a local terminal's
    /// scrollback printed above its first prompt. Commands that were running
    /// do not restart. A Cloud VM workspace, an SSH workspace whose host does
    /// not connect, SSH terminals' scrollback and tabs nothing here shows stay
    /// in classic; `summary` names each.
    ///
    /// - Parameters:
    ///   - created: told the new workspace's id as soon as it exists, before
    ///     its layout is built (the ledger records it, so a cut-off run can close it).
    /// - Returns: the new workspace's id, or nil when nothing of it comes over.
    func importClassicWorkspace(_ saved: ClassicSessionWorkspace, into target: String, frame: CGRect?,
                                summary: inout ClassicImportSummary, unreachable: inout Set<String>,
                                on host: DaemonService? = nil,
                                created: (String) async -> Void) async throws -> String? {
        let windows = services.windows
        let logger = services.daemon.logger
        if saved.cloudVM != nil {
            summary.leftCloudVMs = true
            return nil
        }
        let daemon: DaemonService
        do {
            if let remote = saved.remote, unreachable.contains(remote.sshDestination) { throw DaemonError.notConnected }
            if let host, host.connection != nil { daemon = host } else { daemon = try await classicDaemon(for: saved.remote) }
        } catch {
            summary.leftSSH = true
            if let remote = saved.remote { unreachable.insert(remote.sshDestination) }
            logger.error("classic SSH workspace did not connect: \(String(describing: error), privacy: .public)")
            return nil
        }
        // A workspace with nothing that comes over (only a markdown viewer, or
        // only pages on a daemon without browser tabs) is not opened.
        let browsers = daemon.supports(DaemonCapability.frontendBrowserTabs.rawValue)
        if saved.leftOutPanels { summary.leftTabs = true }
        guard let layout = saved.layout.keeping({ browsers || $0.url == nil }) else { return nil }
        if saved.remote != nil, layout.tabs.contains(where: { $0.scrollback != nil }) { summary.leftSSHScrollback = true }
        var node = WorkspaceBlueprint.Node.pane([])
        do {
            node = blueprintNode(layout, replays: saved.remote == nil)
            // Recreated in their saved order: each one after the last loose row. An
            // explicit slot, because the daemon itself puts a new workspace at the
            // `workspaces.newPlacement` slot (after the current workspace by default).
            var spawn = WorkspaceSpawn(cwd: saved.workingDirectory, name: saved.name)
            spawn.slot = .bottom(anchor: nil)
            // That slot goes through the personal placement queue once the daemon lists the workspace.
            let listed = FirstOutcome<Void>()
            spawn.onListed = { _, _ in listed.resolve(()) }
            // The workspace's first terminal is the first tab's.
            if case .terminal(_, let replay?)? = node.tabs.first { spawn.env = [WorkspaceBlueprintBuilder.replayKey: replay] }
            let id = try await windows.createWorkspace(spawn, on: daemon, into: target, frame: frame)
            await created(id)
            guard let connection = daemon.connection else { throw ClassicImportFailure.noDaemon }
            try await restoreClassicLayout(node, workspaceID: id, browsers: browsers, daemon: daemon, connection: connection)
            let placed = try await restoreClassicTitles(layout, workspaceID: id, connection: connection)
            // Adopted chats run in this Mac's acpmux, which has only this
            // Mac's sessions: an SSH workspace's agent stays a terminal.
            if daemon.isLocal { await openClassicChats(placed, on: daemon, connection: connection) }
            // The run sets the workspace's classic group next. A slot placement still queued would land after
            // that, take the workspace out of the group again and delete the group it emptied (#26153).
            await Self.placementLanded(listed, queue: services.personalPlacements, doc: services.sidebarDoc)
            summary.opened += 1
            return id
        } catch {
            // A workspace that did not open leaves no saved scrollback behind.
            for case .terminal(_, let replay?) in node.tabs { try? FileManager.default.removeItem(atPath: replay) }
            logger.error("classic session import failed: \(String(describing: error), privacy: .public)")
            throw error
        }
    }

    /// Waits for a new workspace's slot placement: listed (queued) within 5 s, then
    /// through the queue. A workspace whose window went away is never listed. On the
    /// sidebar document the slot is a document move instead (`sidebar.apply`, not the
    /// queue): its reply must come before the group write too (#28425).
    /// `doc`: the app's own sidebar document.
    private static func placementLanded(_ listed: FirstOutcome<Void>, queue: PersonalPlacementQueue, doc: SidebarDocument) async {
        let bound = DemandTimer(owner: "ClassicImport.placementLanded")
        bound.schedule(after: .seconds(5)) { listed.resolve(()) }
        await listed.value()
        bound.cancel()
        await queue.drained()
        let started = ContinuousClock.now
        await doc.store?.settled()
        // The wait this adds per imported workspace, recorded only while a DEBUG bench runs (ClassicUpgradeSimulationPerfTests).
        BenchSpans.mark(Self.documentSettledSpan, milliseconds: BenchSpans.ms(.now - started))
    }

    /// The bench span of ``placementLanded(_:queue:doc:)``'s wait for the sidebar document.
    static let documentSettledSpan = "classicImport.documentSettled"

    /// The daemon a classic workspace opens on: this Mac's, or the one for
    /// its SSH host once connected. Classic's identity file and SSH options
    /// do not come over; `~/.ssh/config` and the SSH agent apply. A machine
    /// the import added and that did not connect is forgotten again.
    private func classicDaemon(for remote: ClassicSessionRemote?) async throws -> DaemonService {
        guard let remote else { return services.daemon }
        if let seam = owner.classicSSH { return try await connected(seam(remote.sshDestination)) }
        let saved = Set(services.machines.ssh.map(\.machineID))
        let session = try services.ssh.connect(destination: remote.sshDestination, session: nil, offerInstall: false)
        do {
            return try await connected(session.daemon)
        } catch {
            if !saved.contains(session.machineID) { await services.ssh.forget(session) }
            throw error
        }
    }

    /// The daemon for `remote`'s host, which connects by itself; not waited
    /// for. The migration starts every host at once with it.
    func startClassicDaemon(for remote: ClassicSessionRemote) throws -> DaemonService {
        if let seam = owner.classicSSH { return try seam(remote.sshDestination) }
        return try services.ssh.connect(destination: remote.sshDestination, session: nil, offerInstall: false).daemon
    }

    /// `daemon` once it has a connection, within 20 seconds: woken by the
    /// connection itself, never by polling.
    func connected(_ daemon: DaemonService) async throws -> DaemonService {
        if daemon.connection != nil { return daemon }
        // The first of the connection appearing, the twenty-second SSH connect limit and
        // cancellation resumes the wait once (no task group waits for a loser).
        let outcome = FirstOutcome<Bool>()
        let watch = Task { @MainActor in
            for await ready in ObservationStream({ daemon.connection != nil }) where ready {
                outcome.resolve(true)
                return
            }
        }
        let bound = DemandTimer(owner: "ClassicImport.sshConnect")
        bound.schedule(after: .seconds(20)) { outcome.resolve(false) }
        let ready = await withTaskCancellationHandler {
            await outcome.value()
        } onCancel: {
            outcome.resolve(false)
        }
        watch.cancel()
        bound.cancel()
        try Task.checkCancellation()
        guard ready, daemon.connection != nil else { throw DaemonError.notConnected }
        return daemon
    }

    /// Rebuilds the imported topology through the same daemon builder used by
    /// workspace duplication. It preserves pane splits, tab order, working
    /// directories, pages and replayed scrollback; no saved command runs.
    private func restoreClassicLayout(_ node: WorkspaceBlueprint.Node, workspaceID: String, browsers: Bool,
                                      daemon: DaemonService, connection: DaemonConnection) async throws {
        let blueprint = WorkspaceBlueprint(
            name: workspaceID,
            color: nil,
            icon: nil,
            screens: [WorkspaceBlueprint.Screen(name: nil, columns: [
                WorkspaceBlueprint.Column(width: nil, root: node)
            ])]
        )
        let engine: BrowserEngine = if case .open(let choice) = services.cache.browserTabs.resolve(requested: nil) {
            choice.engine
        } else {
            .webkit
        }
        var builder = WorkspaceBlueprintBuilder(
            connection: connection,
            key: WorkspaceKey(rawValue: workspaceID),
            browsers: browsers,
            defaultEngine: engine
        )
        // A replaying terminal names its own environment: this Mac's terminal one.
        if daemon.isLocal { builder.replayEnvironment = await services.environment.terminalEnvironmentProvider()() }
        try await builder.build(blueprint)
    }

    /// The blueprint of `layout`. With `replays` (a local workspace), a
    /// terminal with scrollback gets it as a private replay file.
    private func blueprintNode(_ layout: ClassicSessionLayout, replays: Bool) -> WorkspaceBlueprint.Node {
        switch layout {
        case .pane(let pane):
            // An agent's terminal holds its place until its chat opens, and
            // replays nothing: its chat has the session's own history.
            return .pane(pane.tabs.map { tab in
                tab.url.map { .browser(url: $0, engine: nil) }
                    ?? .terminal(cwd: tab.agent?.workingDirectory ?? tab.workingDirectory,
                                 replay: replays && tab.agent == nil ? replayFile(tab.scrollback) : nil)
            })
        case .split(let orientation, let ratio, let first, let second):
            return .split(
                direction: orientation == .horizontal ? .right : .down,
                ratio: ratio,
                a: blueprintNode(first, replays: replays),
                b: blueprintNode(second, replays: replays)
            )
        }
    }

    /// `scrollback` written for its terminal's shell to print once; nil when
    /// there is none or it cannot be written (the terminal then starts empty).
    private func replayFile(_ scrollback: String?) -> String? {
        guard let replay = scrollback.flatMap(ClassicScrollbackReplay.init) else { return nil }
        do {
            return try replay.write().path
        } catch {
            services.daemon.logger.error("classic scrollback not written: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// Names each tab as classic did and returns where each one landed.
    private func restoreClassicTitles(_ layout: ClassicSessionLayout, workspaceID: String,
                                      connection: DaemonConnection) async throws -> [ClassicPlacedTab] {
        let tree = try await connection.listWorkspaces()
        guard let workspace = tree.workspaces.first(where: { $0.key?.rawValue == workspaceID }),
              let screen = workspace.screens.first else { return [] }
        var placed: [ClassicPlacedTab] = []
        for paneID in screen.layout.paneIDs {
            guard let pane = screen.panes.first(where: { $0.id == paneID }) else { continue }
            placed += pane.tabs.enumerated().map { ClassicPlacedTab(pane: paneID, index: $0.offset, surface: $0.element.surface) }
        }
        for (index, tab) in layout.tabs.enumerated() where index < placed.count {
            placed[index].tab = tab
            guard let title = tab.title, !title.isEmpty else { continue }
            // A page whose tab takes no name keeps the page's title.
            if tab.url != nil { try? await connection.renameTab(placed[index].surface, to: title) }
            else { try await connection.renameTab(placed[index].surface, to: title) }
        }
        return placed
    }

    /// Replaces each agent's terminal with a chat resuming its session
    /// (acpmux adopt), at the terminal's place in its pane. The terminal
    /// stays when a tab already resumes that session, when acpmux would not
    /// adopt it (its Open Chat plan), or when the chat does not open.
    private func openClassicChats(_ placed: [ClassicPlacedTab], on daemon: DaemonService, connection: DaemonConnection) async {
        for slot in placed {
            guard let tab = slot.tab, let agent = tab.agent else { continue }
            let adopt = AgentPaneAdopt(harness: agent.harness, agentSessionId: agent.sessionID)
            let cwd = agent.workingDirectory ?? tab.workingDirectory
            do {
                guard services.agentTabs.tab(resuming: adopt) == nil,
                      case .adopt? = try await classicChatPlan(adopt, cwd: cwd)?.action else { continue }
                let pending = try services.agentTabs.open(
                    in: slot.pane, of: daemon,
                    seed: AgentPaneSeedSource(AgentPaneSeed(cwd: cwd, adopt: adopt)),
                    adopt: adopt)
                guard let created = try await pending.result?.value else { continue }
                try await connection.moveTab(created.surface, to: slot.pane, index: slot.index)
                try await connection.closeTab(slot.surface)
            } catch {
                services.daemon.logger.error("classic agent session did not open: \(String(describing: error), privacy: .public)")
            }
        }
    }
}

extension AppOnboardingServices {
    /// What this Mac's acpmux would do with `adopt` (Open Chat's plan); nil
    /// when acpmux is not available.
    fileprivate func classicChatPlan(_ adopt: AgentPaneAdopt, cwd: String?) async throws -> AcpmuxChatOpenPlan? {
        if let seam = owner.classicChatPlan { return try await seam(adopt, cwd) }
        guard let environment = QuitAgents.environment(services) else { return nil }
        return try await environment.chatOpenPlan(key: "\(adopt.harness):\(adopt.agentSessionId)", cwd: cwd)
    }
}

/// A classic tab and the daemon tab made for it.
private struct ClassicPlacedTab {
    var pane: PaneID
    var index: Int
    var surface: SurfaceID
    var tab: ClassicSessionTab?
}

private enum ClassicImportFailure: Error {
    /// The new workspace's daemon has no connection to build its panes on.
    case noDaemon
}
