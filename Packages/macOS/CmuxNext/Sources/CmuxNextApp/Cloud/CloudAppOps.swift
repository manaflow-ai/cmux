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
/// Forks a Cloud chat at its latest completed turn. ForkRuns snapshots the machine first;
/// the child daemon then asks acpmux to copy that chat through the same turn.
@MainActor
enum CloudTryAnotherApproach {
    private static func failure(_ message: String) -> NSError {
        NSError(domain: "cloud.tryAnotherApproach", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    static func run(chat key: String, throughSeq: Int, services: AppServices) async throws -> [String: Any] {
        guard throughSeq > 0, services.cloud.auth.isSignedIn else { throw failure("Cloud chat is unavailable") }
        guard let (sourceTab, sourcePane) = services.locateTab(key),
              let sourceRecord = sourceTab.agentSession,
              let sourceSession = sourceRecord.session,
              let harness = sourceRecord.harness else {
            throw failure("Cloud chat is unavailable")
        }
        let sourceDaemon = services.machines.daemon(forTab: sourceTab)
        guard let sourceCloud = services.machines.session(sourceDaemon.machineID),
              let workspace = services.machines.allWorkspaces.first(where: { workspace, daemon in
                  daemon === sourceDaemon && workspace.screens.flatMap(\.panes).contains { $0 === sourcePane }
              })?.0 else {
            throw failure("Cloud chat is unavailable")
        }

        let clientKey = "cmux-next-try-another-approach-\(key)-\(sourceSession)-\(throughSeq)"
        let owner = CloudOwnerAPIClient(
            baseURL: FeedService.apiBaseURL(auth: services.cloud.auth),
            accessToken: { try await services.cloud.auth.tokens().access },
            teamID: { nil })
        let children = try await owner.forkRun(
            workspace: workspace.id,
            clientKey: clientKey,
            sourceMachine: sourceCloud.machineID,
            session: sourceSession,
            harnesses: [harness])
        guard let childMachine = children.first?.machineId else {
            throw failure("Cloud did not return a child machine")
        }

        await services.cloud.refresh(ifOlderThan: .zero)
        guard let childSession = services.machines.session(childMachine) else {
            throw failure("Child machine is not connected")
        }
        let childDaemon = childSession.daemon
        guard let parentTab = childDaemon.store.workspaces
                .flatMap(\.screens)
                .flatMap(\.panes)
                .flatMap(\.tabs)
                .first(where: { $0.agentSession?.session == sourceSession }),
              let parentPane = childDaemon.store.pane(holding: parentTab) else {
            throw failure("Child machine did not restore the parent chat")
        }

        let parentLabel = "Try another approach · \(workspace.displayName)"
        let attach = AgentSessionAttachClient(
            surface: parentTab.surface.rawValue,
            endpoint: { try await childDaemon.endpoint() })
        let forked: (session: String, data: Data)
        do {
            forked = try await attach.fork(throughSeq: throughSeq, name: parentLabel)
        } catch {
            await attach.close()
            throw error
        }
        await attach.close()

        // The remote-child admission path requires a trusted parent link before the tab is opened.
        RemoteAgentSessionLinks.shared.noteFork(forked.session, parent: sourceSession)
        let pending: AgentTabPending
        do {
            pending = try services.agentTabs.open(
                in: parentPane.handle,
                of: childDaemon,
                session: forked.session,
                idempotencyKey: clientKey)
        } catch {
            throw error
        }
        let created = try await pending.value()
        return [
            "childMachine": childMachine,
            "childSession": forked.session,
            "childTab": created.key,
            "parentLabel": parentLabel,
            "throughSeq": throughSeq,
        ]
    }
}
