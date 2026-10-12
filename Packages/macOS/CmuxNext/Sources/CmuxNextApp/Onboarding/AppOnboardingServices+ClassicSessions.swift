import CmuxNextAgentPane
import CmuxNextDaemon
import CmuxNextOnboarding
import Foundation

/// What `workspace.importClassic` opened and what it left in classic.
struct ClassicImportSummary: Equatable {
    var opened = 0
    /// Cloud VM workspaces: cmux-next cannot reach a classic VM.
    var leftCloudVMs = false
    /// SSH workspaces whose host did not connect.
    var leftSSH = false
}

/// Classic cmux session import (Leo, cx-aha.5), run by `workspace.importClassic`
/// (cx-rwlb, cx-1uacm): started by the person or an agent, never on launch.
extension AppOnboardingServices {

    /// Opens each workspace of classic's last saved session here: local and
    /// SSH workspaces with their splits, terminal tabs in their folders,
    /// browser tabs on their pages and agent sessions as chats resuming them.
    /// Classic commands and scrollback are left out; Cloud VM workspaces, and
    /// SSH workspaces whose host does not connect, stay in classic.
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
            guard let layout = saved.layout.keeping({ browsers || $0.url == nil }) else { continue }
            do {
                // Recreated in their saved order: each one after the last loose row. An
                // explicit slot, because the daemon itself puts a new workspace at the
                // `workspaces.newPlacement` slot (top by default).
                var spawn = WorkspaceSpawn(cwd: saved.workingDirectory, name: saved.name)
                spawn.slot = .bottom(anchor: nil)
                let id = try await windows.createWorkspace(spawn, on: daemon, into: target)
                guard let connection = daemon.connection else { throw ClassicImportFailure.noDaemon }
                try await restoreClassicLayout(layout, workspaceID: id, browsers: browsers, connection: connection)
                let placed = try await restoreClassicTitles(layout, workspaceID: id, connection: connection)
                // Adopted chats run in this Mac's acpmux, which has only this
                // Mac's sessions: an SSH workspace's agent stays a terminal.
                if daemon.isLocal { await openClassicChats(placed, on: daemon, connection: connection) }
                summary.opened += 1
            } catch {
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

    /// `daemon` once it has a connection, within 20 seconds.
    private func connected(_ daemon: DaemonService) async throws -> DaemonService {
        let deadline = ContinuousClock.now + .seconds(20)
        while daemon.connection == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(200))
        }
        guard daemon.connection != nil else { throw DaemonError.notConnected }
        return daemon
    }

    /// Rebuilds the imported topology through the same daemon builder used by
    /// workspace duplication. It preserves pane splits, tab order, working
    /// directories and pages without replaying any saved command or scrollback.
    private func restoreClassicLayout(_ layout: ClassicSessionLayout, workspaceID: String, browsers: Bool,
                                      connection: DaemonConnection) async throws {
        let blueprint = WorkspaceBlueprint(
            name: workspaceID,
            color: nil,
            icon: nil,
            screens: [WorkspaceBlueprint.Screen(name: nil, columns: [
                WorkspaceBlueprint.Column(width: nil, root: blueprintNode(layout))
            ])]
        )
        let engine: BrowserEngine = if case .open(let choice) = services.cache.browserTabs.resolve(requested: nil) {
            choice.engine
        } else {
            .webkit
        }
        try await WorkspaceBlueprintBuilder(
            connection: connection,
            key: WorkspaceKey(rawValue: workspaceID),
            browsers: browsers,
            defaultEngine: engine
        ).build(blueprint)
    }

    private func blueprintNode(_ layout: ClassicSessionLayout) -> WorkspaceBlueprint.Node {
        switch layout {
        case .pane(let pane):
            // An agent's terminal holds its place until its chat opens.
            return .pane(pane.tabs.map { tab in
                tab.url.map { .browser(url: $0, engine: nil) } ?? .terminal(cwd: tab.agent?.workingDirectory ?? tab.workingDirectory)
            })
        case .split(let orientation, let ratio, let first, let second):
            return .split(
                direction: orientation == .horizontal ? .right : .down,
                ratio: ratio,
                a: blueprintNode(first),
                b: blueprintNode(second)
            )
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
