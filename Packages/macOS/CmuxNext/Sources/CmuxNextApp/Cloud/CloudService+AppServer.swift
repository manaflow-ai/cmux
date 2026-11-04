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

    /// A machine's record where it was made: `cloud.machine.get` on the app server link (`/api/vm` has
    /// no Worker machine and answers "Cloud VM vm_… was not found."), `GET /api/vm/{id}` otherwise.
    func machineRecord(_ id: String) async throws -> CloudMachine {
        configuration.linkSource == .appServer ? try await Self.appServerRecord(id, ops: appOps) : try await api.machine(id)
    }

    static func appServerRecord(_ id: String, ops: CloudAppOp) async throws -> CloudMachine {
        guard let machine = CloudMachine(next: try await ops("cloud.machine.get", .object(["machine": .string(id)]), nil, .script))
        else { throw CloudAppOpFailure(code: "cmux.cloud.bad_response", message: "cloud.machine.get answered no machine") }
        return machine
    }

    /// The record and stats; the Worker has no stats route, so there the stats are the record's state.
    func machineStatus(_ id: String) async throws -> (record: CloudMachine, stats: CloudMachineStats) {
        guard configuration.linkSource != .appServer else { let r = try await machineRecord(id); return (r, CloudMachineStats(state: r.status.rawValue)) }
        async let stats = api.stats(id), record = api.machine(id)
        return try await (record, stats)
    }

    /// One `cloud.machine.create` (or `cloud.environment.boot` for `environment`) through
    /// ``CloudMachineCreateFlow``, with the request's one idempotency key (cmuxterm-hq#4709): the
    /// creation's Retry sends the same key to the same team, so a create whose answer was lost
    /// answers its first machine instead of making a second.
    func appServerCreate(name: String?, startedByPerson: Bool, asksFirst: Bool = true, askedBy: String?, environment: String? = nil,
                         creation: CloudMachineCreation?, request: CloudMachineRequest,
                         onSent: @escaping @MainActor @Sendable () async -> Void,
                         persistSent: (@MainActor @Sendable (String) async throws -> Void)? = nil) async throws -> CloudMachine {
        let pinned = creation?.request ?? request
        let identity = installIdentity
        let currentTeam: @Sendable () async throws -> String = { MacInstallIdentity.team(ofToken: try await identity.installToken()) ?? "" }
        // The team the relay's create bills: the install token's team claim, captured now. A Retry
        // stays with the first send's team, and is refused if the token now bills another one.
        let team = try Self.appServerTeam(current: try await currentTeam(), request: pinned)
        let sent: @MainActor @Sendable () async throws -> Void = { [weak creation] in
            try await persistSent?(team)
            creation?.markRequestSent(team: team)
            await onSent()
        }
        let flow = appServerFlow(team: team, run: Self.pinnedRun(team: team, currentTeam: currentTeam, sent: sent, ops: appOps))
        // A Worker machine runs once its bind registers the VM install in the creator's user record, which each Worker
        // deployment refuses for a user it has none of: the machine would stay provisioning. `user.ensure` is idempotent.
        // Every attempt asks with its own key: a same-key retry would replay a failed ensure.
        _ = try? await appOps("user.ensure", .object([:]), "user-ensure-" + UUID().uuidString.lowercased(), .user)
        // A request already sent once (its Retry) goes to the server's lookup of its key, past the local plan gate.
        let record: JSONValue
        do {
            record = try await flow.create(name: name, startedByPerson: startedByPerson, asksFirst: asksFirst, askedBy: askedBy, key: pinned.idempotencyKey,
                                           approved: pinned.approvedRequest, onApproved: { [weak creation] in creation?.markApproved($0, key: pinned.idempotencyKey) },
                                           answering: pinned.answeringRequest, onAnswering: { [weak creation] in creation?.markAnswering($0, key: pinned.idempotencyKey) },
                                           gate: pinned.wasSent ? .allowed : createGate, environment: environment, request: pinned,
                                           madeRoom: { [weak self] in self?.madeRoom?(CloudMachine(next: $0)?.title ?? $0["name"]?.stringValue ?? "") })
        } catch let failure as CloudAppOpFailure where CloudMachineCreateRetry().isDefinitiveRefusal(failure) {
            // The key's stored answer is this refusal; only an uncertain outcome keeps the key. A cancelled
            // attempt (a Retry already started, with this same key) leaves the key to that Retry.
            if !Task.isCancelled { creation?.renewKey(replacing: pinned.idempotencyKey) }
            throw failure
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

    /// The team's Cloud environments for the New Cloud Workspace dialog; none when the list fails
    /// (the dialog then offers only a new one).
    func appServerEnvironmentOptions() async -> [CloudWorkspaceSetupWizard.EnvironmentOption] {
        guard let answer = try? await appOps("cloud.environment.list", .object([:]), nil, .script) else { return [] }
        return (answer["environments"]?.arrayValue ?? []).compactMap { value in
            guard let id = value["id"]?.stringValue, let name = value["name"]?.stringValue else { return nil }
            return CloudWorkspaceSetupWizard.EnvironmentOption(id: id, name: name)
        }
    }

    /// Saves a new environment (`cloud.environment.set`) for the New Cloud Workspace dialog; its id.
    func appServerSaveEnvironment(_ new: CloudWorkspaceSetupWizard.NewEnvironment) async throws -> String {
        let args: JSONValue = .object(["name": .string(new.name), "repo": .string(new.repo.spec), "setup_script": .string(new.setupScript)])
        let answer = try await appOps("cloud.environment.set", args, UUID().uuidString, .user)
        guard let id = answer["environment"]?["id"]?.stringValue else {
            throw CloudAppOpFailure(code: "cmux.cloud.bad_response", message: "cloud.environment.set answered no environment")
        }
        return id
    }

    /// The approval-aware flow every person-confirmed app-server op runs through; `run` sends each
    /// call, and `team` is the team its approvals are answered for.
    private func appServerFlow(team: String, run: @escaping CloudAppOp) -> CloudMachineCreateFlow {
        let approvals = CloudApprovalAnswer(call: sessionCall()) { [approvalHolds] in await approvalHolds.isAnswered($0, team: $1) }
        return CloudMachineCreateFlow(
            run: run,
            confirm: { [weak self] prompt in await self?.confirmCreate?(prompt) ?? false },
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
        try CloudMachineCreateRetry().team(current: current, request: request, changedTeam: ActionFailure(message: CloudStrings.createRetryOtherTeam))
    }

    nonisolated static func pinnedRun(team: String, currentTeam: @escaping @Sendable () async throws -> String,
                                      sent: @escaping @MainActor @Sendable () async throws -> Void, ops: @escaping CloudAppOp) -> CloudAppOp {
        CloudMachineCreateRetry().pinnedRun(team: team, currentTeam: currentTeam, sent: sent,
            changedTeam: { ActionFailure(message: CloudStrings.createRetryOtherTeam) }, ops: ops)
    }

    /// POSTs to the API Worker as the signed-in person (Stack session), the
    /// way the feed does; used only to answer a G8 approval after the
    /// person's native confirmation. Never on the relay path.
    private func sessionCall() -> CloudApprovalAnswer.Call {
        let base = FeedService.apiBaseURL(auth: auth)
        let auth = auth
        let session = Self.sessionTransport
        return { path, body in
            var request = URLRequest(url: base.appendingPathComponent(path))
            request.httpMethod = "POST"
            request.timeoutInterval = 15
            request.setValue("application/json", forHTTPHeaderField: "content-type")
            request.setValue("Bearer \(try await auth.tokens().access)", forHTTPHeaderField: "authorization")
            request.httpBody = body
            return try await session.data(for: request).0
        }
    }

    /// No cache, no cookies, and redirects refused: the Stack bearer never
    /// follows one (as `InstallHTTPTransport`).
    private static let sessionTransport: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 15
        return URLSession(configuration: configuration, delegate: CloudRefuseRedirects(), delegateQueue: nil)
    }()
}

extension CloudPresenter {
    /// Confirms a Cloud machine create: true only for the person's click on Create; no window answers
    /// false. An agent's or a script's request waits in the sidebar's card (`asks`), the backend's hold in a sheet.
    /// `chatOpen` says whether an agent chat is still open: a card its asking chat had goes, a no, when the chat closes.
    @MainActor static func confirmCreate(_ prompt: CloudMachineCreateFlow.Prompt, in window: NSWindow?, asks: SidebarAsks?,
                                         chatOpen: @escaping @MainActor @Sendable (String) -> Bool = { _ in true }, stopAsking: (@MainActor () async -> Void)? = nil) async -> Bool {
        let intro: String, machine: CloudMachineCreateFlow.Machine
        switch prompt {
        case .agentRequest(let asked): (intro, machine) = (CloudStrings.createRequestDetail, asked)
        case .approval(_, let held): (intro, machine) = (CloudStrings.createConfirmApproval, held)
        }
        let lines = (machine.name.map { [CloudStrings.createConfirmName($0)] } ?? []) + (machine.sizeShown ? [CloudStrings.createConfirmSize(cpu: machine.cpu, memoryGB: machine.memoryMB / 1024, diskGB: machine.diskMB / 1024)] : [])
        if case .agentRequest = prompt, let asks { return window != nil ? await CloudCreateRequestAsk.ask(asks, intro: intro, lines: lines, asker: machine.askedBy, present: chatOpen, stopAsking: stopAsking) : false }
        // A cancelled wait (the hold answered elsewhere) dismisses the sheet (CmuxDialogCenter.present).
        guard let window else { return false }
        return await CmuxDialogCenter.shared.present(confirmSpec(CloudStrings.createConfirmTitle, ([intro] + lines).joined(separator: "\n"),
                                                                 button: CloudStrings.createConfirmButton, identifier: createConfirmIdentifier), in: .window(window)).button == "confirm"
    }
}
