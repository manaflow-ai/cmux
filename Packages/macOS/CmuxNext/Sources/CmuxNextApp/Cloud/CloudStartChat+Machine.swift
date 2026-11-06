import CmuxNextActions
import CmuxNextAgentPane
import CmuxNextCloud
import CmuxNextCloudUI
import CmuxNextDaemon
import Foundation

/// Which Cloud machine a `cloud.startChat` send runs on is cmux-tui's call (`cmux link start-chat
/// plan`, `link/start_chat_cli/pick.rs`): this person's free machine or one named for chats, never
/// a teammate's or a lane-pool VM, else a new one named for chats; a retry of the same send stays on
/// the machine its first try took. The App lists its machines for it, makes the machine it asks
/// for, and connects (Leo, 2026-10-30: "AS MUCH RUST AS POSSIBLE INSTEAD OF SWIFT").
/// Each send is kept under the account it began in (``CloudStartCore/accountText(_:)``), and takes a machine only
/// of the list the server answered for that account (``checkAccount(_:now:listCurrent:)``).
extension CloudStartChat {
    /// The plan's request: the send's key, account and Mac workspace, who is signed in, the machines the account's list named (as the pick
    /// reads them), the store's others (`stored`: kept for a pin, never picked), and the chat's folder, environment and token flag (`access`).
    static func planRequest(key: String, account: [String?], workspace: String?, user: String?, machines: [CloudMachineSession],
                            local: String? = nil, stored: [String], environment: String? = nil, access: Bool = false, reservationKey: String? = nil,
                            platform: String? = nil, team: String? = nil, ensureProject: Bool? = nil) -> String {
        let listed: [[String: Any]] = machines.map { session in
            let connected = session.daemon.connection != nil
            let chats = connected ? session.daemon.store.workspaces.flatMap(\.screens).flatMap(\.panes).flatMap(\.tabs)
                .filter { $0.agentSession != nil }.count : nil
            return session.machine.startChatPlanEntry(connected: connected, chats: chats)
        }
        var request: [String: Any] = ["key": key, "account": CloudStartCore().accountText(account), "loaded": true, "machines": listed,
                                      "stored": stored, "credential_on_stdin": access, "reservation_key": reservationKey, "platform": platform, "team": team, "ensure_project": ensureProject]
        for (name, value) in [("user", user), ("workspace", workspace), ("local", local), ("environment", environment)] { request[name] = value }
        let data = (try? JSONSerialization.data(withJSONObject: request, options: [.sortedKeys])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
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
    static func checkAccount(_ asked: [String?], now: [String?], listCurrent: Bool) throws { // the rule: cmux-cloud-start-core `start`
        guard let check = CloudStartCore().checkAccount(asked, now: now, listCurrent: listCurrent) else { return }
        throw CloudMove.Failure(message: check == .accountChanged ? CloudMoveStrings.startChatAccountChanged : CloudMoveStrings.startChatListUnread)
    }

    /// The machine for the send `start`, connected, and the plan's keys. Only a machine of the list
    /// the server answered for `account`, the account the send began in. A new one is named and sized
    /// for the chat (`pick`) and pinned to the send before anything runs there. `workspace`: the Mac
    /// workspace the send began in.
    func machine(for start: AgentPaneCloudStart, account: [String?], workspace: String?, cli: CloudMoveCLI, invocation: ActionInvocation,
                 pick: () async -> CloudWorkPick?) async throws -> (CloudMachineSession, CloudMoveCLI.StartChatPlan) {
        let machines = services.machines, cloud = services.cloud
        if !cloud.hasLoadedCurrentMachines { await cloud.refresh() }
        try await importKeptSends(cli)
        try Self.checkAccount(account, now: cloud.account, listCurrent: cloud.hasLoadedCurrentMachines)
        let listed = cloud.listedMachineIDs
        let ensureProject = (account.last ?? nil) == nil && !cloud.auth.configuration.isProductionAuth
        let team = start.reservationKey != nil ? try await cloud.reservationTeam() : nil
        let access = try? await (ensureProject || start.reservationKey != nil ? cloud.auth.tokens().access : nil)
        let request = Self.planRequest(key: start.key, account: account, workspace: workspace, user: cloud.auth.user?.id,
                                       machines: machines.cloud.filter { listed.contains($0.machineID) }, local: start.home ? nil : start.uploadRoot ?? start.cwd,
                                       stored: machines.cloud.map(\.machine).keptForPin(listed: listed), environment: start.environment, access: access != nil,
                                       reservationKey: start.reservationKey, platform: cloud.configuration.artifactsAPIBaseURL()?.absoluteString, team: team, ensureProject: ensureProject)
        var plan = try Self.checked(await cli.startChatPlan(request: request, access: access))
        var invocation = invocation
        if let id = plan.machine, !listed.contains(id) {
            await cloud.refresh() // List a platform-reserved or project machine before attaching.
            // A remembered machine that is gone (deleted, or of another backend) is dropped, never
            // shown: the send makes a new machine instead (DEV 9fa9b1c3: "No Cloud machine has the
            // id vm_c813daded688a74e806f." on a first send).
            if machines.session(id) == nil {
                cloud.logger.info("cloud start chat: the planned machine \(id, privacy: .public) is gone; making a new one")
                plan.machine = nil
                plan.createSent = false
            }
        }
        if let id = plan.machine {
            invocation.arguments["machine"] = .string(id)
        } else {
            if !plan.createSent {
                _ = try Self.checked(await cli.startChatCreateBegin(key: start.key, account: CloudStartCore().accountText(account), name: plan.newName ?? "cloud-chats", createKey: plan.createKey))
            }
            var request = CloudMachineRequest(startChatKey: plan.createKey, sizedFor: await pick(), team: plan.createTeam ?? (account.last ?? nil))
            request.wasSent = plan.createSent
            try Self.checkAccount(account, now: cloud.account, listCurrent: cloud.hasLoadedCurrentMachines)
            // The account is checked again once the server answered, before the machine joins the list.
            let created: CloudMachineSession
            do {
                created = try await cloud.createMachine(name: plan.newName, startedByPerson: invocation.origin == .user,
                                                            request: request, onAppServerSent: { team in
                    _ = try Self.checked(await cli.startChatCreateSent(key: start.key, account: CloudStartCore().accountText(account), team: team, createKey: plan.createKey))
                }) {
                    try Self.checkAccount(account, now: cloud.account, listCurrent: true)
                }
            } catch let failure as CloudAppOpFailure where !Task.isCancelled && CloudMachineCreateRetry().isDefinitiveRefusal(failure) {
                _ = try Self.checked(await cli.startChatCreateRefused(key: start.key, account: CloudStartCore().accountText(account), createKey: plan.createKey))
                throw failure
            }
            // Unpinned, a retry would plan afresh and could open the chat on another machine.
            _ = try Self.checked(await cli.startChatPin(key: start.key, account: CloudStartCore().accountText(account), machine: created.machineID, workspace: workspace))
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
