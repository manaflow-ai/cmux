import CmuxNextAgentActivity
import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextDaemonService
import Foundation

/// One row of the Chief view gallery (webviews/src/pages/chief-views/types.ts `ChiefAgent`): an
/// acpmux chat on this Mac or a peer it mirrors (its lane, #20363), or an agent in a terminal
/// that reports through a hook. Plain values, so the page provider and the tests need no store.
struct ChiefViewsAgent: Hashable, Sendable {
    enum Kind: String, Sendable { case chat, terminal }
    /// The four words the views use.
    enum State: String, Sendable { case working, waiting, idle, failed }

    var id: String
    var kind: Kind
    var name: String
    var title: String
    /// `local` for this Mac, else the acpmux peer, or a remote terminal's machine name (its id when unnamed).
    var machine: String
    var machineName: String?
    var folder: String?
    var state: State
    var task: String?
    var error: String?
    var lastOutputAt: Date?
    var since: Date?
    var createdAt: Date?
    var harness: String?
    var branch: String?
    var parent: String?

    static let localMachine = "local"

    /// A lane as a row. A lost agent reads as failed: its process is gone without an answer.
    init(lane: AgentActivityLane) {
        id = lane.id
        kind = .chat
        name = lane.name
        title = lane.title
        machine = lane.peer ?? Self.localMachine
        machineName = lane.peer
        folder = lane.cwd
        state = switch lane.state {
        case .working: .working
        case .input: .waiting
        case .idle: .idle
        case .failed, .lost: .failed
        }
        // acpmux's masked step only, never a raw prompt (#21794).
        task = lane.step
        error = lane.error
        lastOutputAt = lane.updatedAt
        since = lane.since
        createdAt = lane.createdAt
        harness = lane.harness
        branch = nil
        parent = lane.parent
    }

    /// A terminal whose agent reports through a hook. Its last prompt stays out: it is the
    /// person's own text, unmasked, and the row is shown beside the Chief.
    init(terminal id: String, title: String, status: AgentStatus, machine: String, machineName: String?,
         folder: String?, branch: String?) {
        self.id = id
        kind = .terminal
        name = title
        self.title = title
        self.machine = machine
        self.machineName = machineName
        self.folder = folder
        state = switch status.state {
        case .working: .working
        case .blocked: .waiting
        case .idle, .done, .unknown: .idle
        }
        task = nil
        error = nil
        lastOutputAt = status.updatedAtMs > 0 ? Date(timeIntervalSince1970: Double(status.updatedAtMs) / 1000) : nil
        since = status.sinceMs.map { Date(timeIntervalSince1970: Double($0) / 1000) }
        createdAt = nil
        harness = status.agent
        self.branch = branch
        parent = nil
    }
}

extension ChiefViewsAgent {
    /// Every agent the app mirrors: the lanes (this Mac's acpmux and its peers'), then the
    /// terminals with a live hook agent on every machine of `workspaces` (the app's
    /// `MachineRegistry.allWorkspaces`). A chat tab is an acpmux session, so it is already a lane.
    /// Reading this inside an `ObservationStream` tracks every value it reads.
    static func current(lanes: AgentLaneStore, workspaces: [(WorkspaceModel, DaemonService)],
                        machineName: (DaemonService) -> String?) -> [ChiefViewsAgent] {
        var agents = lanes.lanes.values.sorted { $0.id < $1.id }.map(ChiefViewsAgent.init(lane:))
        for (workspace, daemon) in workspaces {
            // Keyed by the machine's name when it has one, the word acpmux names the same machine's
            // peer by, so its chats and terminals group together; else by its id.
            let name = daemon.isLocal ? nil : machineName(daemon)
            let machine = daemon.isLocal ? localMachine : name ?? daemon.machineID
            for tab in workspace.screens.flatMap(\.panes).flatMap(\.tabs) {
                guard tab.agentSession == nil, !tab.dead, let status = tab.agent else { continue }
                let title = TabItemMapping.shared.item(tab, fallbackTitle: ChiefViewsStrings.untitledTerminal).title
                agents.append(ChiefViewsAgent(terminal: tab.id, title: title, status: status, machine: machine,
                                              machineName: name, folder: tab.cwd, branch: tab.gitBranch))
            }
        }
        return agents
    }
}
