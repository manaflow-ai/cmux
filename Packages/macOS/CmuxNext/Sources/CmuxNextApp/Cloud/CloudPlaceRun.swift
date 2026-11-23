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

/// The chat place controls' actions (`chatPlace.set`, `chatMove.cancel`, `chatMove.retry`, `cloudEvacuate`) and the runs
/// behind Auto: Swift draws and calls, Rust decides (``CloudPlaceFlows``).
@MainActor
struct CloudPlaceRun {
    static let set: ActionID = "chatPlace.set"
    static let cancel: ActionID = "chatMove.cancel"
    static let retry: ActionID = "chatMove.retry"
    static let evacuate: ActionID = "cloudEvacuate"

    let services: AppServices

    /// A chat tab of some machine, with the session its place is kept by.
    struct Chat {
        var tab: TabModel
        var session: String
        var onCloud: Bool
    }

    /// Every chat tab the app shows, local first: a local chat of this Mac, or a Cloud one a move from this Mac put there.
    func chats() -> [Chat] {
        var found: [Chat] = [], seen = Set<String>()
        for daemon in services.machines.daemons {
            let local = daemon.isLocal
            for workspace in daemon.store.workspaces {
                for tab in workspace.screens.flatMap(\.panes).flatMap(\.tabs) {
                    guard let record = tab.agentSession, let session = record.session ?? services.agentTabs.sessions[services.agentTabs.tabKey(of: tab)],
                          seen.insert(session).inserted else { continue }
                    let cloud = record.host.hasPrefix(MachineRegistry.registryHostPrefix)
                    if local, !cloud, !record.host.hasPrefix(ChiefHomeAcpmux.hostPrefix) {
                        found.append(Chat(tab: tab, session: session, onCloud: false))
                    } else if cloud, services.cloud.movedChats.entry(host: record.host, session: session) != nil {
                        found.append(Chat(tab: tab, session: session, onCloud: true))
                    }
                }
            }
        }
        return found
    }

    func chat(of invocation: ActionInvocation, context: AppActionContext) -> Chat? {
        guard let (tab, _) = context.daemonTab(invocation), let record = tab.agentSession,
              let session = record.session ?? services.agentTabs.sessions[services.agentTabs.tabKey(of: tab)] else { return nil }
        return Chat(tab: tab, session: session, onCloud: record.host.hasPrefix(MachineRegistry.registryHostPrefix))
    }

    // MARK: Actions

    /// `chatPlace.set {mode}`: records the mode, and moves the chat where the mode puts it now (Cloud: to its own VM; Local: back).
    func setMode(_ invocation: ActionInvocation, context: AppActionContext) throws {
        guard let mode = invocation["mode"]?.stringValue, ["local", "cloud", "auto"].contains(mode) else { throw ActionFailure(message: "mode must be local, cloud or auto") }
        guard let chat = chat(of: invocation, context: context) else { return }
        services.cloud.place.setMode(mode, of: chat.session)
        switch mode {
        case "cloud" where !chat.onCloud: move(chat, toCloud: true, trigger: .person)
        case "local" where chat.onCloud: move(chat, toCloud: false, trigger: .person)
        case "auto": services.cloud.autoMonitor?.evaluate() // the monitor decides (``CloudAutoMonitor``), starting now
        default: break
        }
    }

    /// `chatMove.cancel`: the reducer decides whether the move stops (through `sync`) or finishes.
    func cancelMove(_ invocation: ActionInvocation, context: AppActionContext) {
        guard let chat = chat(of: invocation, context: context) ?? session(of: invocation) else { return }
        services.cloud.place.cancel(chat.session)
    }

    /// `chatMove.retry`: what the stop recorded (``CloudMoveRetries``), run again as the person's.
    func retryMove(_ invocation: ActionInvocation, context: AppActionContext) {
        guard let chat = chat(of: invocation, context: context) else { return }
        run(chat, toCloud: !chat.onCloud, arguments: [:], trigger: .person)
    }

    /// `cloudEvacuate {sessions?}`: every local chat (or the named ones) to its own VM, `parallel` at a time.
    func evacuate(_ invocation: ActionInvocation) {
        struct Chat: Encodable { var session: String, at: String, started: Bool, turnRunning: Bool, moving: Bool }
        struct Request: Encodable { var chats: [Chat], selected: [String]? }
        struct Plan: Decodable { var moves: [String], parallel: Int }
        let all = chats()
        let named = invocation["sessions"]?.stringValue.map { $0.split(separator: ",").map(String.init) }
        let request = Request(chats: all.map { chat in
            Chat(session: chat.session, at: chat.onCloud ? "cloud" : "local", started: true, // a chat with no first message refuses to move
                 turnRunning: CloudPlaceCargo.read(tab: chat.tab, session: chat.session, services: services).turnRunning,
                 moving: services.cloud.place.isMoving(chat.session) || services.cloud.movingBack.contains(chat.tab.id))
        }, selected: named)
        guard let plan = CloudMoveCore().call("place_evacuate", request, as: Plan.self) else { return }
        let queue = plan.moves.compactMap { session in all.first { $0.session == session } }
        // task-owner: one-shot; ends when the last move's work ends (each move is tracked by the registry).
        Task {
            var next = queue.makeIterator()
            await withTaskGroup(of: Void.self) { group in
                func launch() -> Bool {
                    guard let chat = next.next() else { return false }
                    let works = move(chat, toCloud: true, trigger: .evacuate)
                    group.addTask { for work in works { _ = await work.value } }
                    return true
                }
                for _ in 0..<max(1, plan.parallel) { if !launch() { break } }
                for await _ in group { _ = launch() }
            }
        }
    }

    // MARK: Running a move

    /// Runs the chat's move to or from Cloud (the same actions the menus run), to its own VM when going to Cloud.
    /// Returns the work the registry tracked, for a caller that waits (Evacuate's limit).
    @discardableResult
    func move(_ chat: Chat, toCloud: Bool, trigger: CloudPlaceFlows.Trigger) -> [ActionWork] {
        var arguments: [String: ActionValue] = [:]
        if toCloud, let own = ownMachine(for: chat.session) {
            switch own {
            case .reuse(let id): arguments["machine"] = .string(id)
            case .create: arguments["newMachine"] = .bool(true)
            }
        }
        return run(chat, toCloud: toCloud, arguments: arguments, trigger: trigger)
    }

    @discardableResult
    private func run(_ chat: Chat, toCloud: Bool, arguments: [String: ActionValue], trigger: CloudPlaceFlows.Trigger) -> [ActionWork] {
        var arguments = arguments
        arguments["trigger"] = .string(trigger.argument)
        let invocation = ActionInvocation(target: ActionTargetRef(kind: .tab, id: chat.tab.id), arguments: arguments, origin: .user)
        let registry = services.registry
        let action = toCloud ? CloudMove.action : CloudBringBack.action
        return registry.capturingWork { _ = registry.perform(action, invocation: invocation) }
    }

    private func session(of invocation: ActionInvocation) -> Chat? {
        guard let session = invocation["session"]?.stringValue, let chat = chats().first(where: { $0.session == session }) else { return nil }
        return chat
    }

    // MARK: The chat's own VM

    enum Own { case reuse(String), create }

    /// One VM per agent: the VM this chat used before when it is still there and holds no other chat, else a new one
    /// (Rust's rule, `cloud_move_place_own_machine`). Nil when the FFI does not answer: the move picks its machine as before.
    func ownMachine(for session: String) -> Own? {
        struct Machine: Encodable { var id: String, sessions: [String], gone: Bool }
        struct Request: Encodable { var session: String, before: String?, machines: [Machine] }
        struct Reply: Decodable {
            var action: String, machine: String?
            enum CodingKeys: String, CodingKey { case action = "do", machine }
        }
        let ledger = services.cloud.movedChats.all()
        let before = ledger.first { $0.session == session || $0.broughtBack?.session == session }?.machineID
        let machines = services.machines.cloud.map { machine in
            Machine(id: machine.machineID, sessions: ledger.filter { $0.machineID == machine.machineID && $0.broughtBack == nil }.map(\.session),
                    gone: [.deleting, .destroyed].contains(machine.machine.status))
        }
        guard let reply = CloudMoveCore().call("place_own_machine", Request(session: session, before: before, machines: machines), as: Reply.self) else { return nil }
        return reply.action == "reuse" ? reply.machine.map(Own.reuse) : .create
    }
}
