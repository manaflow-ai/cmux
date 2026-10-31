import CmuxNextActions
import CmuxNextAgentPane
import CmuxNextCloud
import CmuxNextDaemon
import Foundation

/// Which Cloud machine a `cloud.startChat` send runs on is cmux-tui's call (`cmux link start-chat
/// plan`, `link/start_chat_cli/pick.rs`): its Mac workspace's own machine, else a new one ("we'll want
/// a vm for every single workspace"); a retry stays on its first try's. The App lists its machines for
/// it, makes the machine it asks for, and connects (Leo, 2026-10-30: "AS MUCH RUST AS POSSIBLE").
extension CloudStartChat {
    /// The plan's request: the send's key, its Mac workspace, who is signed in, and every Cloud machine.
    static func planRequest(key: String, workspace: String?, user: String?, loaded: Bool, machines: [CloudMachineSession]) -> String {
        let listed: [[String: Any]] = machines.map { session in
            let connected = session.daemon.connection != nil
            var machine: [String: Any] = ["id": session.machineID, "title": session.machine.title,
                                          "status": session.machine.status.rawValue, "connected": connected]
            machine["slug"] = session.machine.slug
            machine["created_by"] = session.machine.createdBy
            machine["pause_reason"] = session.machine.pauseReason?.rawValue
            if connected {
                machine["chats"] = session.daemon.store.workspaces.flatMap(\.screens).flatMap(\.panes).flatMap(\.tabs)
                    .filter { $0.agentSession != nil }.count
            }
            return machine
        }
        var request: [String: Any] = ["key": key, "loaded": loaded, "machines": listed]
        request["user"] = user
        request["workspace"] = workspace
        let data = (try? JSONSerialization.data(withJSONObject: request, options: [.sortedKeys])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    /// The create of the machine for a send: sized for the chat, under the send's own idempotency
    /// key (the plan's `create_key`), so a retry after a create whose answer was lost gets the same
    /// machine from the server, never a second paid VM.
    static func createRequest(key: String, sizedFor pick: CloudWorkPick?) -> CloudMachineRequest {
        var request = CloudChatPick.request(sizedFor: pick)
        request.idempotencyKey = key
        return request
    }

    /// The machine for the send `start`, connected, and the plan's keys. A new one is named and
    /// sized for the chat (`pick`) and pinned to the send before anything runs there.
    func machine(for start: AgentPaneCloudStart, cli: CloudMoveCLI, invocation: ActionInvocation,
                 pick: () async -> CloudWorkPick?) async throws -> (CloudMachineSession, CloudMoveCLI.StartChatPlan) {
        let machines = services.machines, cloud = services.cloud, workspace = services.workspaceID(ofTab: invocation.target.id)
        let request = Self.planRequest(key: start.key, workspace: workspace, user: cloud.auth.user?.id, loaded: cloud.hasLoadedMachines, machines: machines.cloud)
        let plan = try Self.checked(await cli.startChatPlan(request: request))
        var invocation = invocation
        if let id = plan.machine {
            invocation.arguments["machine"] = .string(id)
        } else {
            let created = try await cloud.createMachine(name: plan.newName, startedByPerson: invocation.origin == .user,
                                                        request: Self.createRequest(key: plan.createKey, sizedFor: await pick()))
            // Unpinned, a retry would plan afresh and could open the chat on another machine.
            _ = try Self.checked(await cli.startChatPin(key: start.key, machine: created.machineID, workspace: workspace))
            invocation.arguments["machine"] = .string(created.machineID)
        }
        return (try await CloudMove(services: services).machine(invocation, pick: pick), plan)
    }

    /// `answer`, or its error as the person reads it.
    static func checked<T>(_ answer: (CloudMoveCLI.Answer, T)) throws -> T {
        guard answer.0.ok else {
            throw CloudMove.Failure(message: CloudMoveStrings.moveFailed(answer.0.error ?? answer.0.errorCode ?? ""))
        }
        return answer.1
    }
}
