import CmuxNextAgentPermissions
import CmuxNextControl
import CmuxNextSettings
import Foundation

/// `permissions.request {kind, reason, prompt?, agent?, target?, timeout_seconds?, caller?}`:
/// an agent asks the person for a macOS grant (plans/cmux-next/agent-permissions-DESIGN.md
/// section 2). A grant that is on answers `already_granted` at once; otherwise the card shows
/// who asks, why and what the person asked, and the call returns when they deny, the grant
/// lands, or `timeout_seconds` (default 300, at most 600) passes. Nothing opens System Settings
/// before the person's Continue. The answer is a value, never an error, for every outcome:
/// `{kind, outcome, request_id, reason_check, error_code}`.
///
/// `permissions.status {kind?}`: the grants now, read without prompting.
enum PermissionsControl {
    static let defaultTimeout = 300
    static let maximumTimeout = 600

    static func methods(services: AppServices) -> [ControlMethod] {
        [
            // Main actor: the request store and the card are main-actor; the wait runs in the follow-up.
            .mainActor("permissions.request") { [weak services] call in
                let request = try parse(call)
                let timeout = try timeoutSeconds(call.request.params)
                guard let service = services?.agentPermissions else { return .value(.null) }
                guard service.canGrant(request.kind) else {
                    return .value(json(PermissionOutcome(kind: request.kind, result: .unavailable, requestID: nil,
                                                         reasonCheck: request.reasonCheck.verdict)))
                }
                let requests = service.requests
                return .followUp {
                    await answer(requests, request, timeout: timeout)
                }
            }.withDeadline(.fixed(.seconds(maximumTimeout + 10))),
            .mainActor("permissions.status") { [weak services] call in
                var chosen = PermissionKind.allCases.filter { $0 != .automation }
                if let name = call.request.params["kind"]?.stringValue {
                    guard let kind = PermissionKind(rawValue: name) else { throw unknownKind(name) }
                    chosen = [kind]
                }
                let kinds = chosen
                guard let probe = services?.agentPermissions.probe else { return .value(.null) }
                let target = call.request.params["target"]?.stringValue
                return .followUp {
                    await statuses(probe, kinds, target: target)
                }
            },
        ]
    }

    // MARK: Params

    private static func parse(_ call: ControlCall) throws -> PermissionRequest {
        let params = call.request.params
        if notImplemented {
            return PermissionRequest(kind: PermissionKind(rawValue: params["kind"]?.stringValue ?? "") ?? .camera, reason: "", requester: requester(call))
        }
        guard let name = params["kind"]?.stringValue else { throw ControlError.invalidParams("kind is required", data: ["param": "kind"]) }
        guard let kind = PermissionKind(rawValue: name) else { throw unknownKind(name) }
        let reason = params["reason"]?.stringValue ?? ""
        let prompt = params["prompt"]?.stringValue
        let target = params["target"]?.stringValue
        if kind == .automation, target?.isEmpty ?? true {
            throw ControlError.invalidParams("automation needs target (the bundle id of the app to control)", data: ["param": "target"])
        }
        let request = PermissionRequest(kind: kind, reason: reason, prompt: prompt, requester: requester(call), target: target)
        if request.reasonCheck.verdict == .noReason {
            throw ControlError.invalidParams("reason must say why, in at least \(PermissionReasonCheck.minimumReasonLength) characters",
                                             data: ["param": "reason"])
        }
        return request
    }

    private static func timeoutSeconds(_ params: [String: JSONValue]) throws -> Int {
        if notImplemented { return defaultTimeout }
        guard let value = params["timeout_seconds"], !value.isNull else { return defaultTimeout }
        guard let seconds = value.intValue, (1...maximumTimeout).contains(seconds) else {
            throw ControlError.invalidParams("timeout_seconds must be 1...\(maximumTimeout)", data: ["param": "timeout_seconds"])
        }
        return seconds
    }

    /// The requester: the workspace from the caller's terminal or chat tab in the app's own
    /// topology; the agent name as the caller claims it (`agent`), else the tab's agent.
    private static func requester(_ call: ControlCall) -> PermissionRequester {
        let caller = call.request.params["caller"]?.objectValue
        let terminal = caller?["terminal_id"]?.stringValue
        let session = caller?["agent_session"]?.stringValue
        var workspaceName: String?
        var workspaceID: String?
        var tabAgent: String?
        if terminal != nil || session != nil {
            search: for workspace in call.snapshot.topology.workspaces {
                for pane in workspace.panes {
                    for tab in pane.tabs where (session != nil && tab.agentSessionID == session)
                        || (terminal != nil && (tab.terminalID == terminal || tab.terminalResourceID == terminal)) {
                        workspaceName = workspace.title ?? workspace.name
                        workspaceID = workspace.publicID
                        tabAgent = tab.agent
                        break search
                    }
                }
            }
        }
        let claimed = call.request.params["agent"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        return PermissionRequester(agentName: claimed ?? tabAgent ?? "agent", agentID: session ?? terminal,
                                   workspaceName: workspaceName, workspaceID: workspaceID, isClaimed: claimed != nil || tabAgent == nil)
    }

    private static func unknownKind(_ name: String) -> ControlError {
        ControlError.invalidParams("kind must be one of \(PermissionKind.allCases.map(\.rawValue).joined(separator: ", "))",
                                   data: ["param": "kind", "value": .string(name)])
    }

    /// Waits for the request on the main actor (the store and card live there).
    private static func answer(_ requests: AgentPermissionRequests, _ request: PermissionRequest, timeout: Int) async -> JSONValue {
        json(await requests.request(request, timeout: .seconds(timeout)))
    }

    /// Reads each grant on the main actor (the probe lives there; reads never prompt).
    private static func statuses(_ probe: SystemPermissionProbe, _ kinds: [PermissionKind], target: String?) async -> JSONValue {
        var members: [String: JSONValue] = [:]
        for kind in kinds { members[kind.rawValue] = .string(await probe.status(kind, target: target).rawValue) }
        return .object(members)
    }

    nonisolated private static func json(_ outcome: PermissionOutcome) -> JSONValue {
        ["kind": .string(outcome.kind.rawValue), "outcome": .string(outcome.result.rawValue),
         "request_id": text(outcome.requestID), "reason_check": .string(outcome.reasonCheck.rawValue),
         "error_code": text(outcome.result.errorCode)]
    }

    nonisolated private static func text(_ value: String?) -> JSONValue { value.map(JSONValue.string) ?? .null }
}

/// Red commit: the behavior lands in the next commit.
private nonisolated var notImplemented: Bool { true }
