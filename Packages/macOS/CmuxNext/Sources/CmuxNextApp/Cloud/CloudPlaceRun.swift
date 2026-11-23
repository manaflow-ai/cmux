import CmuxNextActions
import CmuxNextAgentPane
import CmuxNextBridge
import CmuxNextCloud
import CmuxNextCloudPlace
import CmuxNextDaemon
import Foundation

/// What a chat carries into a move, read from the app's own state for the reducer's `Cargo`.
/// Not read yet (no Swift source for them): the queue (0), the branch (nil) and the dirty file count (0).
@MainActor
enum CloudPlaceCargo {
    static func read(tab: TabModel, session: String, services: AppServices) -> CloudPlaceFlows.Cargo {
        var cargo = CloudPlaceFlows.Cargo()
        if let ref = tab.agentSession { cargo.turnRunning = AgentTurnStateStore.shared.state(for: ref) == .working }
        // Move to Cloud and Bring Back Local freeze the chat and carry a running turn to where it lands (``CloudMove``'s agent move).
        cargo.continuesTurn = true
        let tabs = services.agentTabs
        cargo.hasDraft = tabs.unsentDrafts.hasDraft(tabs.resolve(tab.id), machine: tabs.daemonListing(tab)?.machineID)
        return cargo
    }
}

/// The app's side of the chat place controls (``CloudPlaceDriver``): its chats, how it runs a move, what its ledger knows.
@MainActor
final class CloudPlaceApp: CloudPlaceHost {
    static let set: ActionID = "chatPlace.set"
    static let cancel: ActionID = "chatMove.cancel"
    static let retry: ActionID = "chatMove.retry"
    static let evacuate: ActionID = "cloudEvacuate"

    private unowned let services: AppServices
    private var tabs: [String: TabModel] = [:]

    init(services: AppServices) { self.services = services }

    func placeChats() -> [CloudPlaceChat] {
        var found: [CloudPlaceChat] = [], seen = Set<String>()
        tabs = [:]
        for daemon in services.machines.daemons {
            for workspace in daemon.store.workspaces {
                for tab in workspace.screens.flatMap(\.panes).flatMap(\.tabs) {
                    guard let record = tab.agentSession, let session = record.session ?? services.agentTabs.sessions[services.agentTabs.tabKey(of: tab)],
                          seen.insert(session).inserted else { continue }
                    let cloud = record.host.hasPrefix(MachineRegistry.registryHostPrefix)
                    guard daemon.isLocal && !cloud && !record.host.hasPrefix(ChiefHomeAcpmux.hostPrefix)
                        || cloud && services.cloud.movedChats.entry(host: record.host, session: session) != nil else { continue }
                    tabs[tab.id] = tab
                    found.append(CloudPlaceChat(id: tab.id, session: session, onCloud: cloud, turnRunning: CloudPlaceCargo.read(tab: tab, session: session, services: services).turnRunning,
                                                turnStartedAtMs: AgentTurnStateStore.shared.detail(for: record)?.turnStartedAtMs.map(Double.init),
                                                moving: services.cloud.place.isMoving(session) || services.cloud.movingBack.contains(tab.id)))
                }
            }
        }
        return found
    }

    func placeRun(_ chat: CloudPlaceChat, toCloud: Bool, machine: CloudPlaceMachine?, trigger: CloudPlaceFlows.Trigger) async {
        var arguments: [String: ActionValue] = ["trigger": .string(trigger.argument)]
        switch machine {
        case .reuse(let id): arguments["machine"] = .string(id)
        case .create: arguments["newMachine"] = .bool(true)
        case nil: break
        }
        let invocation = ActionInvocation(target: ActionTargetRef(kind: .tab, id: chat.id), arguments: arguments, origin: .user)
        let registry = services.registry
        let action = toCloud ? CloudMove.action : CloudBringBack.action
        for work in registry.capturingWork({ _ = registry.perform(action, invocation: invocation) }) { _ = await work.value }
    }

    func placeOwnFacts(_ session: String) -> (before: String?, machines: [CloudPlaceOwnMachine]) {
        let ledger = services.cloud.movedChats.all()
        return (ledger.first { $0.session == session || $0.broughtBack?.session == session }?.machineID,
                services.machines.cloud.map { machine in
                    CloudPlaceOwnMachine(id: machine.machineID, sessions: ledger.filter { $0.machineID == machine.machineID && $0.broughtBack == nil }.map(\.session),
                                         gone: [.deleting, .destroyed].contains(machine.machine.status))
                })
    }

    func placeOnTurnEnded(_ handler: @escaping @MainActor (String) -> Void) {
        AgentTurnStateStore.shared.turnEndedObservers.append { session, _ in handler(session) }
    }
}
