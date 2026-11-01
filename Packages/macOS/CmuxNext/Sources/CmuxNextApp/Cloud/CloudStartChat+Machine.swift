import CmuxNextActions
import CmuxNextAgentPane
import CmuxNextCloud
import CmuxNextDaemon
import Foundation

/// Which Cloud machine a `cloud.startChat` send runs on is cmux-tui's call (`cmux link start-chat
/// plan`, `link/start_chat_cli/pick.rs`): this person's free machine or one named for chats, never
/// a teammate's or a lane-pool VM, else a new one named for chats; a retry of the same send stays on
/// the machine its first try took. The App lists its machines for it, makes the machine it asks
/// for, and connects (Leo, 2026-10-30: "AS MUCH RUST AS POSSIBLE INSTEAD OF SWIFT").
/// Each send is kept under the account it began in (``accountText(_:)``), and takes a machine only
/// of the list the server answered for that account (``checkAccount(_:now:listCurrent:)``).
extension CloudStartChat {
    /// The account a send began in as cmux-tui keeps its sends: its user and team. A team switch keeps
    /// the user signed in, so a send of the previous team never names this team's machine.
    static func accountText(_ account: [String?]) -> String {
        account.map { $0 ?? "" }.joined(separator: "/")
    }

    /// The plan's request: the send's key, account and Mac workspace, who is signed in, the machines the account's list named (as the pick
    /// reads them), the store's others (`stored`: kept for a pin, never picked), and the chat's folder, environment and token flag (`access`).
    static func planRequest(key: String, account: [String?], workspace: String?, user: String?, machines: [CloudMachineSession],
                            local: String? = nil, stored: [String], environment: String? = nil, access: Bool = false) -> String {
        let listed: [[String: Any]] = machines.map { session in
            let connected = session.daemon.connection != nil
            let chats = connected ? session.daemon.store.workspaces.flatMap(\.screens).flatMap(\.panes).flatMap(\.tabs)
                .filter { $0.agentSession != nil }.count : nil
            return session.machine.startChatPlanEntry(connected: connected, chats: chats)
        }
        var request: [String: Any] = ["key": key, "account": accountText(account), "loaded": true, "machines": listed,
                                      "stored": stored, "credential_on_stdin": access]
        for (name, value) in [("user", user), ("workspace", workspace), ("local", local), ("environment", environment)] { request[name] = value }
        let data = (try? JSONSerialization.data(withJSONObject: request, options: [.sortedKeys])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    /// The create of the machine for a send: sized for the chat, under the send's own idempotency key
    /// (the plan's `create_key`), so a retry after a create whose answer was lost gets the same
    /// machine from the server, never a second paid VM. Its team is the send's (`team`, the account's
    /// team when the send began), fixed for every try, so a team switch during a slow create never
    /// makes the machine in the other team.
    static func createRequest(key: String, sizedFor pick: CloudWorkPick?, team: String?) -> CloudMachineRequest {
        var request = CloudChatPick.request(sizedFor: pick)
        request.idempotencyKey = key
        request.team = team
        return request
    }

    /// Where this App kept its sends before cmux-tui did. Handed over once, so a send in flight keeps its machine and copy.
    static let keptSendsKey = "cmux.cloud.startChatDestinations"

    /// Hands the sends this App kept itself to cmux-tui, then forgets them. A failed hand-over refuses the send and keeps them.
    func importKeptSends(_ cli: CloudMoveCLI) async throws {
        guard let defaults = services.cloud.move.ledger, let data = defaults.data(forKey: Self.keptSendsKey) else { return }
        _ = try Self.checked(await cli.startChatImport(entries: String(decoding: data, as: UTF8.self)))
        defaults.removeObject(forKey: Self.keptSendsKey)
    }

    /// Refuses a send whose account changed since it began (`asked`), or whose machine list is not
    /// the server's answer for the account signed in now (`listCurrent`): after a team switch the
    /// previous team's machines stay in the store until that list lands, and the chat's folder must
    /// never be copied to one of them.
    static func checkAccount(_ asked: [String?], now: [String?], listCurrent: Bool) throws {
        guard asked == now else { throw CloudMove.Failure(message: CloudMoveStrings.startChatAccountChanged) }
        guard listCurrent else { throw CloudMove.Failure(message: CloudMoveStrings.startChatListUnread) }
    }

    /// The machine for the send `start`, connected, and the plan's keys. Only a machine of the list
    /// the server answered for `account`, the account the send began in. A new one is named and sized
    /// for the chat (`pick`) and pinned to the send before anything runs there.
    func machine(for start: AgentPaneCloudStart, account: [String?], cli: CloudMoveCLI, invocation: ActionInvocation,
                 pick: () async -> CloudWorkPick?) async throws -> (CloudMachineSession, CloudMoveCLI.StartChatPlan) {
        let machines = services.machines, cloud = services.cloud, workspace = invocation.target.flatMap { services.workspaceID(ofTab: $0.id) }
        if !cloud.hasLoadedCurrentMachines { await cloud.refresh() }
        try await importKeptSends(cli)
        try Self.checkAccount(account, now: cloud.account, listCurrent: cloud.hasLoadedCurrentMachines)
        let listed = cloud.listedMachineIDs, access = try? await ((account.last ?? nil) == nil && !cloud.auth.configuration.isProductionAuth ? cloud.auth.tokens().access : nil)
        let request = Self.planRequest(key: start.key, account: account, workspace: workspace, user: cloud.auth.user?.id,
                                       machines: machines.cloud.filter { listed.contains($0.machineID) }, local: start.home ? nil : start.uploadRoot ?? start.cwd,
                                       stored: machines.cloud.map(\.machine).keptForPin(listed: listed), access: access != nil)
        let plan = try Self.checked(await cli.startChatPlan(request: request, access: access))
        var invocation = invocation
        if let id = plan.machine {
            if !listed.contains(id) { await cloud.refresh() } // the platform's (personal, non-production sign-ins, where workspace machines are served): list it for the attach
            invocation.arguments["machine"] = .string(id)
        } else {
            let request = Self.createRequest(key: plan.createKey, sizedFor: await pick(), team: account.last ?? nil)
            try Self.checkAccount(account, now: cloud.account, listCurrent: cloud.hasLoadedCurrentMachines)
            // The account is checked again once the server answered, before the machine joins the list.
            let created = try await cloud.createMachine(name: plan.newName, startedByPerson: invocation.origin == .user,
                                                        request: request) {
                try Self.checkAccount(account, now: cloud.account, listCurrent: true)
            }
            // Unpinned, a retry would plan afresh and could open the chat on another machine.
            _ = try Self.checked(await cli.startChatPin(key: start.key, account: Self.accountText(account), machine: created.machineID, workspace: workspace))
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
