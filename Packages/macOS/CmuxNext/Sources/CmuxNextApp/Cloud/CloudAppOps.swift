import CmuxNextAgentPane
import CmuxNextCloud
import CmuxNextDaemon
import Foundation

/// Cloud ops through the Cloud app server (`cmux/cloud`, contract 2.1):
/// `apps-run` on the local daemon; the server checks the args and origin,
/// keeps the machine projection, and reaches the cmux-next API Worker
/// through the host credential relay (install token, `CloudCredentialProvider`).
/// Never `/api/vm`.
nonisolated struct CloudAppOpFailure: Error, Equatable, Sendable, CustomStringConvertible {
    /// The server's code (`cmux.cloud.<reason>`).
    var code: String
    var message: String
    var details: JSONValue?

    static let approvalPending = "cmux.cloud.approval_pending"
    /// The op needs a paid plan (`cloud.plan.required`).
    static let planRequired = "cmux.cloud.plan_required"

    /// The approval request id (`apr_…`) of an approval code.
    var approvalRequest: String? { details?["request"]?.stringValue }

    var description: String { message.isEmpty ? code : message }
}

/// One Cloud app op: `op`, JSON `args`, an idempotency key for a mutation
/// (nil for a read), and the wire origin.
typealias CloudAppOp = @Sendable (_ op: String, _ args: JSONValue, _ key: String?, _ origin: AppsRunRequest.Origin) async throws -> JSONValue

extension CloudAppLinks {
    /// Runs Cloud app ops on `local`'s current connection. A refusal is a
    /// ``CloudAppOpFailure``; origin `user` is sent only where the daemon
    /// allows it (the verified app connection), never upgraded here.
    static func ops(local: DaemonService) -> CloudAppOp {
        let timeout = connectTimeout
        return { op, args, key, origin in
            guard let connection = await local.connection else {
                throw CloudAppOpFailure(code: "cmux.cloud.relay_unavailable", message: DaemonError.notConnected.description)
            }
            let allowed = await connection.userOriginAllowed
            let request = AppsRunRequest(app: CloudLinkKey.app, op: op, args: args, idempotencyKey: key,
                                         origin: origin == .user && allowed ? .user : .script)
            do {
                return try await connection.request(request, timeout: timeout).value
            } catch DaemonError.command(_, let message, let code, let details, _) {
                throw CloudAppOpFailure(code: code ?? "", message: message, details: details)
            }
        }
    }
}

extension CloudMachine {
    /// A `CloudMachine` record of the cmux-next backend (contract 1.2), as
    /// the Cloud app server answers it.
    init?(next value: JSONValue) {
        guard let id = value["id"]?.stringValue, !id.isEmpty else { return nil }
        let status: Status = switch value["status"]?.stringValue {
        case "provisioning", "starting": .provisioning
        case "running": .running
        case "pausing", "paused": .paused
        case "deleting": .destroyed
        case "failed": .failed
        default: .unknown
        }
        // The record's `capabilities` are machine capability names
        // (`agent_session`, …), not provider operations, so the machine
        // declares none and every Cloud action stays available.
        // The idle auto-pause fields, when the backend sends them (`/api/vm` names).
        let minutes = (value["idlePauseMinutes"]?.doubleValue).flatMap { Int(exactly: $0) }
        let idlePause = Self.idlePauseDiagnostics(value["idlePause"])
        self.init(id: id, provider: "cmux-next", status: status, displayName: value["name"]?.stringValue,
                  pauseReason: value["pauseReason"]?.stringValue.flatMap(PauseReason.init(rawValue:)), idlePauseMinutes: minutes,
                  idlePause: idlePause)
    }

    private static func idlePauseDiagnostics(_ value: JSONValue?) -> IdlePauseDiagnostics? {
        guard let value, case let .object(fields) = value,
              let minutes = fields["minutes"]?.doubleValue.flatMap({ Int(exactly: $0) }),
              let privateAddressKnown = fields["privateAddressKnown"]?.boolValue else { return nil }
        let integer: (String, [String: JSONValue]) -> Int? = { key, object in
            object[key]?.doubleValue.flatMap { Int(exactly: $0) }
        }
        let lastDecision: IdlePauseDiagnostics.LastDecision? = fields["lastDecision"].flatMap { value in
            guard case let .object(decision) = value else { return nil }
            guard let at = integer("at", decision), let outcome = decision["outcome"]?.stringValue,
                  let reason = decision["reason"]?.stringValue,
                  let runValue = decision["run"], case let .object(runFields) = runValue,
                  let checked = integer("checked", runFields), let elapsedMs = integer("elapsedMs", runFields) else { return nil }
            return .init(at: at, outcome: outcome, reason: reason, run: .init(checked: checked, elapsedMs: elapsedMs))
        }
        return .init(minutes: minutes, lastCheckedAt: integer("lastCheckedAt", fields),
                     idleSince: integer("idleSince", fields), lastApiActivityAt: integer("lastApiActivityAt", fields),
                     privateAddressKnown: privateAddressKnown, lastDecision: lastDecision)
    }
}
/// App adapters for the latest-turn Cloud fork. The sequence itself lives in CmuxNextCloud.
@MainActor
private func cloudTryAnotherApproach(chat key: String, throughSeq: Int, services: AppServices) async throws -> [String: Any] {
    func failure(_ message: String) -> NSError {
        NSError(domain: "cloud.tryAnotherApproach", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
    var childDaemon: DaemonService?
    var parentPane: Pane?
    return try await CloudTryAnotherApproach.run(
        chat: key, throughSeq: throughSeq,
        prepare: { chat, seq in
            guard seq > 0, services.cloud.auth.isSignedIn,
                  let (sourceTab, sourcePane) = services.locateTab(chat),
                  let sourceRecord = sourceTab.agentSession,
                  let sourceSession = sourceRecord.session,
                  let harness = sourceRecord.harness else { throw failure("Cloud chat is unavailable") }
            let sourceDaemon = services.machines.daemon(forTab: sourceTab)
            guard let sourceCloud = services.machines.session(sourceDaemon.machineID),
                  let workspace = services.machines.allWorkspaces.first(where: { workspace, daemon in
                      daemon === sourceDaemon && workspace.screens.flatMap(\.panes).contains { $0 === sourcePane }
                  })?.0 else { throw failure("Cloud chat is unavailable") }
            return .init(workspace: workspace.id, sourceMachine: sourceCloud.machineID, session: sourceSession,
                         harness: harness, throughSeq: seq,
                         clientKey: "cmux-next-try-another-approach-\(chat)-\(sourceSession)-\(seq)",
                         parentLabel: "Try another approach · \(workspace.displayName)")
        },
        forkMachine: { plan in
            let owner = CloudOwnerAPIClient(
                baseURL: FeedService.apiBaseURL(auth: services.cloud.auth),
                accessToken: { try await services.cloud.auth.tokens().access }, teamID: { nil })
            return try await owner.forkRun(workspace: plan.workspace, clientKey: plan.clientKey,
                                           sourceMachine: plan.sourceMachine, session: plan.session,
                                           harnesses: [plan.harness])
                .first ?? { throw failure("Cloud did not return a child") }()
        },
        forkTranscript: { plan, childMachine in
            await services.cloud.refresh(ifOlderThan: .zero)
            guard let childSession = services.machines.session(childMachine) else {
                throw failure("Child machine is not connected")
            }
            childDaemon = childSession.daemon
            guard let daemon = childDaemon,
                  let parentTab = daemon.store.workspaces.flatMap(\.screens).flatMap(\.panes).flatMap(\.tabs)
                    .first(where: { $0.agentSession?.session == plan.session }),
                  let pane = daemon.store.pane(holding: parentTab) else {
                throw failure("Child machine did not restore the parent chat")
            }
            parentPane = pane
            let attach = AgentSessionAttachClient(surface: parentTab.surface.rawValue,
                                                   endpoint: { try await daemon.endpoint() })
            do {
                let forked = try await attach.fork(throughSeq: plan.throughSeq, name: plan.parentLabel)
                await attach.close()
                RemoteAgentSessionLinks.shared.noteFork(forked.session, parent: plan.session)
                return forked.session
            } catch {
                await attach.close()
                throw error
            }
        },
        openChild: { plan, _, session in
            guard let daemon = childDaemon, let pane = parentPane else { throw failure("Child chat is unavailable") }
            let pending = try services.agentTabs.open(in: pane.handle, of: daemon, session: session,
                                                      idempotencyKey: plan.clientKey)
            return try await pending.value().key
        })
    .map { ["childMachine": $0.childMachine, "childSession": $0.childSession, "childTab": $0.childTab,
            "parentLabel": $0.parentLabel, "throughSeq": $0.throughSeq] }
}
