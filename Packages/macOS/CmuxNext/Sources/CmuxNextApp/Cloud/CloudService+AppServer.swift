import AppKit
import CmuxNextAppCore
import CmuxNextCloud
import CmuxNextCloudUI
import CmuxNextCompat
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextSidebar
import Foundation

/// The Cloud app server path of the machine list and create (cx-t2rz):
/// `cloud.machine.list` / `cloud.machine.create` on `cmux/cloud`, which
/// reaches the cmux-next API Worker through the host credential relay.
extension CloudService {
    /// Every page of `cloud.machine.list` (a read: no key, origin script).
    func appServerMachines() async throws -> [CloudMachine] {
        var machines: [CloudMachine] = []
        var cursor: String?
        // At most 50 pages of 100: a list that never ends is a server bug.
        for _ in 0..<50 {
            var args: [String: JSONValue] = ["limit": .number(100)]
            if let cursor { args["cursor"] = .string(cursor) }
            let page = try await appOps("cloud.machine.list", .object(args), nil, .script)
            machines += (page["machines"]?.arrayValue ?? []).compactMap(CloudMachine.init(next:))
            guard let next = page["next_cursor"]?.stringValue, !next.isEmpty else { return machines }
            cursor = next
        }
        return machines
    }

    /// A machine's record: `cloud.machine.get` on the app server link.
    func machineRecord(_ id: String) async throws -> CloudMachine {
        try await Self.appServerRecord(id, ops: appOps)
    }

    static func appServerRecord(_ id: String, ops: CloudAppOp) async throws -> CloudMachine {
        guard let machine = CloudMachine(next: try await ops("cloud.machine.get", .object(["machine": .string(id)]), nil, .script))
        else { throw CloudAppOpFailure(code: "cmux.cloud.bad_response", message: "cloud.machine.get answered no machine") }
        return machine
    }

    /// The record and stats; the Worker has no stats route, so there the stats are the record's state.
    func machineStatus(_ id: String) async throws -> (record: CloudMachine, stats: CloudMachineStats) {
        let record = try await machineRecord(id)
        return (record, CloudMachineStats(state: record.status.rawValue))
    }

    /// One `cloud.machine.create` through ``CloudMachineCreateFlow`` (`environment`: the platform's ensure, ``CloudMoveCLI/machineInEnvironment(_:key:platform:access:)``), with the
    /// request's one idempotency key (cmuxterm-hq#4709): the creation's Retry sends the same key to the same team on the same route,
    /// so a create whose answer was lost answers its first machine instead of making a second. `ownCreate`: the person's own gesture
    /// started it, so a fresh key goes straight to the Cloud API as the person (``CloudMachineRequest/createRoute(personsOwnCreate:team:)``). `onAnswer` hears the whole answer.
    func appServerCreate(name: String?, startedByPerson: Bool, ownCreate: Bool = false, asksFirst: Bool = true, askedBy: String?, environment: String? = nil,
                         creation: CloudMachineCreation?, request: CloudMachineRequest,
                         onSent: @escaping @MainActor @Sendable () async -> Void,
                         persistSent: (@MainActor @Sendable (String, CloudCreateRoute) async throws -> Void)? = nil, onAnswer: @MainActor (JSONValue) -> Void = { _ in }) async throws -> CloudMachine {
        let pinned = creation?.request ?? request, identity = installIdentity
        let scope = account
        let checkScope: @MainActor @Sendable () throws -> Void = { [weak self] in
            try Task.checkCancellation()
            guard let self, !isSigningOut, account == scope else { throw CancellationError() }
        }
        try checkScope()
        if let environment, let cli = move.cli {
            let access = try await identity.installToken() // The platform route verifies the install token’s team claim.
            await onSent()
            try checkScope()
            let id = try await CloudMoveCLI(binary: cli).machineInEnvironment(
                environment, key: pinned.idempotencyKey, platform: configuration.artifactsAPIBaseURL()?.absoluteString, access: access
            )
            try checkScope()
            if let name, !name.isEmpty { try? await renameMachine(id, to: name) }
            try checkScope()
            return setup.machineEnvironment(try await machineRecord(id), ensured: environment, account: scope, defaults: move.ledger)
        }
        let currentTeam: @Sendable () async throws -> String = { MacInstallIdentity.team(ofToken: try await identity.installToken()) ?? "" }
        // The team the relay's create bills: the install token's team claim, captured now (the direct route sends it as
        // `x-cmux-team`). A Retry stays with the first send's team and route, and is refused if the token now bills another team.
        let team = try Self.appServerTeam(current: try await currentTeam(), request: pinned), route = pinned.createRoute(personsOwnCreate: ownCreate, team: team)
        try checkScope()
        let sent: @MainActor @Sendable () async throws -> Void = { [weak creation] in
            try checkScope()
            try await persistSent?(team, route)
            try checkScope()
            creation?.markRequestSent(team: team, route: route)
            await onSent()
        }
        // A Worker machine runs once its bind registers the VM install in the creator's user record, which each Worker deployment refuses for a
        // user it has none of: the machine would stay provisioning. `user.ensure` (idempotent; its own key each attempt, as a same-key retry would
        // replay a failed one) goes beside the relay's held first call, done before the answer lets the op run; a direct create's, right before it.
        let ensure: @Sendable () async -> Void = { [appOps] in _ = try? await appOps("user.ensure", .object([:]), "user-ensure-" + UUID().uuidString.lowercased(), .user) }
        let ops = route == .direct ? CloudPersonCreate.ops(sessionCall(team: team, checking: checkScope), after: ensure) : appOps
        var flow = appServerFlow(team: team, run: Self.pinnedRun(team: team, currentTeam: currentTeam, sent: sent,
                                                               ops: route.timed(ops)), creation: creation)
        if route == .relay { flow.beside = ensure }
        // A request already sent once (its Retry) goes to the server's lookup of its key, past the local plan gate.
        let record: JSONValue
        do {
            record = try await flow.create(name: name, startedByPerson: startedByPerson, asksFirst: asksFirst, askedBy: askedBy, key: pinned.idempotencyKey,
                                           approved: pinned.approvedRequest, onApproved: { [weak creation] in creation?.markApproved($0, key: pinned.idempotencyKey) },
                                           answering: pinned.answeringRequest, onAnswering: { [weak creation] in creation?.markAnswering($0, key: pinned.idempotencyKey) },
                                           gate: pinned.wasSent ? .allowed : createGate, environment: environment, request: pinned,
                                           madeRoom: { [weak self] in self?.madeRoom?(CloudMachine(next: $0)?.title ?? $0["name"]?.stringValue ?? "") }, answered: onAnswer)
        } catch let failure as CloudAppOpFailure where CloudStartCore().isDefinitiveRefusal(failure) {
            // The key's stored answer is this refusal; only an uncertain outcome keeps the key. A cancelled
            // attempt (a Retry already started, with this same key) leaves the key to that Retry.
            if !Task.isCancelled { creation?.renewKey(replacing: pinned.idempotencyKey) }
            throw failure
        } catch is CloudPersonCreate.Unavailable where !pinned.wasSent && creation?.request.answeringRequest == nil && !Task.isCancelled && persistSent == nil {
            // The direct route refused before the op ran (no usable session, an older server): the relay takes it with a NEW key, never this one (a caller that keeps the key in its own ledger, `persistSent`, takes the new key from it).
            try checkScope()
            var relay = pinned; relay.idempotencyKey = UUID().uuidString; creation?.renewKey(replacing: pinned.idempotencyKey)
            return try await appServerCreate(name: name, startedByPerson: startedByPerson, asksFirst: asksFirst, askedBy: askedBy, environment: environment,
                                             creation: creation, request: relay, onSent: onSent, persistSent: persistSent, onAnswer: onAnswer)
        }
        guard let machine = CloudMachine(next: record) else { throw CloudAppOpFailure(code: "cmux.cloud.bad_response", message: "the create answered no machine") }
        return machine
    }

    /// A money or destructive Cloud op a person started in this app (`cloud.environment.build`,
    /// `.delete`) through the same approval loop as a create; `confirm` is its native confirmation.
    func appServerApprovedCall(_ op: String, args: JSONValue, confirm: @MainActor () async -> Bool) async throws -> JSONValue {
        // The team the approval bills: the install token's team claim, captured now.
        let team = MacInstallIdentity.team(ofToken: try await installIdentity.installToken()) ?? ""
        return try await appServerFlow(team: team, run: appOps).approvedCall(op, args: args, confirm: confirm)
    }

    /// A machine's resize and snapshot ops (`cloud.machine.resize`, `cloud.snapshot.*`) to cmux-platform's op of the same name
    /// (never `/api/vm`), as the person's own: the approval loop (one key, same-key retries), once `allow` says yes. The id of the answer's `record`.
    @discardableResult
    func machineChange(_ op: String, _ args: [String: JSONValue], answers record: String? = nil, allow: @MainActor () async -> Bool) async throws -> String? {
        guard await allow() else { throw CloudMachineCreateFlow.Failure.declined }
        return try await appServerApprovedCall(op, args: .object(args), confirm: { true }).recordID(record, op: op)
    }

    /// The team's Cloud environments (`/v1/cloud-environments`); throws when the list fails (`cloud new-machine --environment NAME` refuses it).
    func appServerEnvironmentOptions() async throws -> [CloudWorkspaceSetupWizard.EnvironmentOption] {
        try await CloudEnvironmentRequest.names(connection: machines.local.connection, platform: configuration.artifactsAPIBaseURL(), accessToken: try await installIdentity.accessToken(team: try await auth.accessTokenTeam(requested: nil)).accessToken).map { .init(id: $0.id, name: $0.name) }
    }

    /// The approval-aware flow every person-confirmed app-server op runs through; `run` sends each
    /// call, and `team` is the team its approvals are answered for. A create's `creation` shown on its
    /// window's progress page asks there; anything else asks in a sheet or the sidebar's card.
    private func appServerFlow(team: String, run: @escaping CloudAppOp, creation: CloudMachineCreation? = nil) -> CloudMachineCreateFlow {
        let approvals = CloudApprovalAnswer(call: sessionCall()) { [approvalHolds] in await approvalHolds.isAnswered($0, team: $1) }
        return CloudMachineCreateFlow(
            run: run,
            confirm: { [weak self, weak creation] prompt in
                if let page = creation?.progressHost, page.window != nil {
                    return await page.provider.ask(CloudPresenter.createAsk(prompt))
                }
                return await self?.confirmCreate?(prompt) ?? false
            },
            approve: { request, op, params in
                try await approvals.approve(request: request, op: op, params: try JSONEncoder().encode(params), team: team)
            },
            pause: { attempt in
                // wakeup-allow: bounded same-key retry of a retryable approval.pending after the person approved (cx-t2rz)
                try await ContinuousClock().sleep(for: CloudMachineCreateFlow.backoff(attempt))
            },
            validateOptions: { [configuration, work] params in
                try await CloudEnvironmentBootstrap(work: work).checkCreate(
                    backend: configuration.ownerAPIBaseURL(), params: JSONEncoder().encode(params))
            }
        )
    }

    static func appServerTeam(current: String, request: CloudMachineRequest) throws -> String {
        try CloudStartCore().createTeam(current: current, request: request, changedTeam: ActionFailure(message: CloudStrings.createRetryOtherTeam))
    }

    nonisolated static func pinnedRun(team: String, currentTeam: @escaping @Sendable () async throws -> String,
                                      sent: @escaping @MainActor @Sendable () async throws -> Void, ops: @escaping CloudAppOp) -> CloudAppOp {
        CloudStartCore().pinnedRun(team: team, currentTeam: currentTeam, sent: sent,
            changedTeam: { ActionFailure(message: CloudStrings.createRetryOtherTeam) }, ops: ops)
    }

    /// POSTs to the API Worker as the signed-in person (Stack session), the way the feed does, in `team` (`x-cmux-team`)
    /// when given: only to answer a G8 approval after the person's native confirmation, and for a person's own create
    /// (``CloudPersonCreate``). The session never goes to the daemon or the relay. The bundled `cmux cloud install-post`
    /// sends it. A create (the call with a team) waits for the provider to make the machine; an approval's calls answer at once.
    private func sessionCall(team: String? = nil, checking check: (@MainActor @Sendable () throws -> Void)? = nil) -> CloudApprovalAnswer.Call {
        let base = FeedService.apiBaseURL(auth: auth), auth = auth, io = auth.machineIO, space = configuration.buildSpace
        let wait = team == nil ? CloudPersonCreate.callTimeout : CloudPersonCreate.createTimeout
        return { path, body in
            let bearer = try await auth.tokens().access
            try await check?()
            let reply = try await InstallHTTPTransport(baseURL: base, buildSpace: space, machineIO: io)
                .send(path, json: body, bearer: bearer, headers: team.flatMap { $0.isEmpty ? nil : ["x-cmux-team": $0] } ?? [:], attempt: wait)
            if reply.resent { CloudPersonCreate.resends?.note() }
            return reply.body
        }
    }
}

extension CloudPresenter {
    /// Confirms a Cloud machine create: true only for the person's click on Create; no window answers
    /// false. An agent's or a script's request waits in the sidebar's card (`asks`), the backend's hold in a sheet.
    /// `chatOpen` says whether an agent chat is still open: a card its asking chat had goes, a no, when the chat closes.
    @MainActor static func confirmCreate(_ prompt: CloudMachineCreateFlow.Prompt, in window: NSWindow?, asks: SidebarAsks?,
                                         chatOpen: @escaping @MainActor @Sendable (String) -> Bool = { _ in true }, stopAsking: (@MainActor () async -> Void)? = nil) async -> Bool {
        let (intro, lines) = createLines(prompt)
        if case .agentRequest(let machine) = prompt, let asks {
            return window != nil ? await CloudCreateRequestAsk.ask(asks, intro: intro, lines: lines, asker: machine.askedBy, present: chatOpen, stopAsking: stopAsking) : false
        }
        // A cancelled wait (the hold answered elsewhere) dismisses the sheet (CmuxDialogCenter.present).
        guard let window else { return false }
        return await CmuxDialogCenter.shared.present(confirmSpec(CloudStrings.createConfirmTitle, ([intro] + lines).joined(separator: "\n"),
                                                                 button: CloudStrings.createConfirmButton, identifier: createConfirmIdentifier), in: .window(window)).button == "confirm"
    }

    /// A create confirmation's first line (who asks) and its machine lines (name, size).
    private static func createLines(_ prompt: CloudMachineCreateFlow.Prompt) -> (intro: String, lines: [String]) {
        let intro: String, machine: CloudMachineCreateFlow.Machine
        switch prompt {
        case .agentRequest(let asked): (intro, machine) = (CloudStrings.createRequestDetail, asked)
        case .approval(_, let held): (intro, machine) = (CloudStrings.createConfirmApproval, held)
        }
        let size = CloudStrings.createConfirmSize(cpu: machine.cpu, memoryGB: machine.memoryMB / 1024, diskGB: machine.diskMB / 1024)
        return (intro, (machine.name.map { [CloudStrings.createConfirmName($0)] } ?? []) + (machine.sizeShown ? [size] : []))
    }

    /// The same confirmation as a question on the creation's progress page: Create or Cancel, as the sheet asks.
    static func createAsk(_ prompt: CloudMachineCreateFlow.Prompt) -> CloudProgressAsk {
        let (intro, lines) = createLines(prompt)
        let kind: CloudProgressAsk.Kind = if case .agentRequest = prompt { .createRequest } else { .approval }
        return CloudProgressAsk(kind: kind, title: CloudStrings.createConfirmTitle, body: ([intro] + lines).joined(separator: "\n"),
                                button: CloudStrings.createConfirmButton, cancel: CloudStrings.cancel)
    }
}
