import CmuxNextAgentPane
import CmuxNextCompat
import CmuxNextDaemon
import CmuxNextOnboarding
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
}

/// Classic cmux session import (Leo, cx-aha.5), run by `workspace.importClassic`
/// (cx-rwlb, cx-1uacm): started by the person or an agent, never on launch.
extension AppOnboardingServices {

    /// Opens each workspace of classic's last saved session here: local and
    /// SSH workspaces with their splits, terminal tabs in their folders,
    /// browser tabs on their pages, agent sessions as chats resuming them, and
    /// a local terminal's scrollback printed above its first prompt. Commands
    /// that were running do not restart. Cloud VM workspaces, SSH workspaces
    /// whose host does not connect, SSH terminals' scrollback and tabs nothing
    /// here shows stay in classic; the summary names each.
    func importClassicSessions() async throws -> ClassicImportSummary {
        let importer = owner.classicSessions
        let workspaces = try await Task.detached { try (importer ?? ClassicSessionImporter()).readForImport() }.value
        let windows = services.windows
        let target = windows.targetWindow(preferring: windows.active?.state.id)
        let logger = services.daemon.logger
        var summary = ClassicImportSummary()
        var lastError: (any Error)?
        // A host that did not connect is not tried again for its other workspaces.
        var unreachable = Set<String>()
        for saved in workspaces {
            if saved.cloudVM != nil {
                summary.leftCloudVMs = true
                continue
            }
            let daemon: DaemonService
            do {
                if let remote = saved.remote, unreachable.contains(remote.sshDestination) { throw DaemonError.notConnected }
                daemon = try await classicDaemon(for: saved.remote)
            } catch {
                summary.leftSSH = true
                if let remote = saved.remote { unreachable.insert(remote.sshDestination) }
                logger.error("classic SSH workspace did not connect: \(String(describing: error), privacy: .public)")
                continue
            }
            // A workspace with nothing that comes over (only a markdown viewer, or
            // only pages on a daemon without browser tabs) is not opened.
            let browsers = daemon.supports(DaemonCapabilities.shared.frontendBrowserTabs)
            if saved.leftOutPanels { summary.leftTabs = true }
            guard let layout = saved.layout.keeping({ browsers || $0.url == nil }) else { continue }
            if saved.remote != nil, layout.tabs.contains(where: { $0.scrollback != nil }) { summary.leftSSHScrollback = true }
            var node = WorkspaceBlueprint.Node.pane([])
            do {
                node = blueprintNode(layout, replays: saved.remote == nil)
                // Recreated in their saved order: each one after the last loose row. An
                // explicit slot, because the daemon itself puts a new workspace at the
                // `workspaces.newPlacement` slot (top by default).
                var spawn = WorkspaceSpawn(cwd: saved.workingDirectory, name: saved.name)
                spawn.slot = .bottom(anchor: nil)
                // The workspace's first terminal is the first tab's.
                if case .terminal(_, let replay?)? = node.tabs.first { spawn.env = [WorkspaceBlueprintBuilder.replayKey: replay] }
                let id = try await windows.createWorkspace(spawn, on: daemon, into: target)
                guard let connection = daemon.connection else { throw ClassicImportFailure.noDaemon }
                try await restoreClassicLayout(node, workspaceID: id, browsers: browsers, daemon: daemon, connection: connection)
                let placed = try await restoreClassicTitles(layout, workspaceID: id, connection: connection)
                // Adopted chats run in this Mac's acpmux, which has only this
                // Mac's sessions: an SSH workspace's agent stays a terminal.
                if daemon.isLocal { await openClassicChats(placed, on: daemon, connection: connection) }
                summary.opened += 1
            } catch {
                // A workspace that did not open leaves no saved scrollback behind.
                for case .terminal(_, let replay?) in node.tabs { try? FileManager.default.removeItem(atPath: replay) }
                lastError = error
                logger.error("classic session import failed: \(String(describing: error), privacy: .public)")
            }
        }
        // One workspace that did not open is logged; none opening is the action's failure.
        if summary.opened == 0, let lastError { throw lastError }
        return summary
    }

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

    /// `daemon` once it has a connection, within 20 seconds: woken by the
    /// connection itself, never by polling.
    private func connected(_ daemon: DaemonService) async throws -> DaemonService {
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
