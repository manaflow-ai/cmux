import CMUXAgentLaunch
import Foundation

/// Socket v2 surface for batch agent permission grants.
///
/// `permissions.request` is only a proposal: it shows the approval panel and
/// writes the grant store after the user clicks Approve Selected. The CLI and
/// agents never write the store. All three methods run on the socket worker;
/// only the panel itself runs on the main actor, and it doesn't activate the
/// app. None of them is permitted through a remote relay.
extension TerminalController {
    /// How long `permissions.request` waits for the user before denying.
    nonisolated static let permissionRequestTimeoutSeconds: TimeInterval = 600

    private nonisolated static var permissionGrantStore: AgentPermissionGrantStore {
        AgentPermissionGrantStore(fileURL: AgentPermissionGrantStore.defaultFileURL())
    }

    // MARK: permissions.request

    nonisolated func v2PermissionsRequest(params: [String: Any]) async -> V2CallResult {
        let proposal: AgentPermissionGrantProposal
        switch AgentPermissionGrantProposal.parse(params: params) {
        case .success(let parsed):
            proposal = parsed
        case .failure(let error):
            return .err(code: "invalid_params", message: Self.permissionValidationMessage(error), data: nil)
        }
        let decision = await AgentPermissionGrantApprovalPanel.requestDecision(for: proposal)
        guard case .approved(let selected) = decision,
              let grant = proposal.grant(approving: selected) else {
            return .ok(["denied": true])
        }
        do {
            try Self.permissionGrantStore.add(grant)
        } catch {
            return .err(
                code: "internal_error",
                message: String(
                    localized: "socket.permissions.saveFailed",
                    defaultValue: "The grant could not be saved."
                ),
                data: nil
            )
        }
        return .ok(["approved": grant.rules, "grant_id": grant.id.uuidString])
    }

    // MARK: permissions.list

    nonisolated func v2PermissionsList() -> V2CallResult {
        .ok(["grants": Self.permissionGrantStore.grants().map(\.socketPayload)])
    }

    // MARK: permissions.revoke

    nonisolated func v2PermissionsRevoke(params: [String: Any]) -> V2CallResult {
        let id: UUID?
        if params["all"] as? Bool == true {
            id = nil
        } else if let raw = params["id"] as? String,
                  let parsed = UUID(uuidString: raw.trimmingCharacters(in: .whitespaces)) {
            id = parsed
        } else {
            return .err(
                code: "invalid_params",
                message: String(
                    localized: "socket.permissions.revokeTarget",
                    defaultValue: "Pass a grant id or all: true."
                ),
                data: nil
            )
        }
        do {
            return .ok(["revoked": try Self.permissionGrantStore.revoke(id: id)])
        } catch {
            return .err(
                code: "internal_error",
                message: String(
                    localized: "socket.permissions.saveFailed",
                    defaultValue: "The grant could not be saved."
                ),
                data: nil
            )
        }
    }

    nonisolated static func permissionValidationMessage(
        _ error: AgentPermissionGrantProposal.ValidationError
    ) -> String {
        switch error {
        case .missingRules:
            return String(localized: "socket.permissions.missingRules",
                          defaultValue: "rules must be a non-empty list of permission rules.")
        case .tooManyRules:
            return String(localized: "socket.permissions.tooManyRules",
                          defaultValue: "Too many rules in one request.")
        case .invalidRule(let rule):
            return String(format: String(localized: "socket.permissions.invalidRule",
                                         defaultValue: "Not a permission rule: %@"), rule)
        case .invalidScope:
            return String(localized: "socket.permissions.invalidScope",
                          defaultValue: "scope must be session or project.")
        case .missingSessionID:
            return String(localized: "socket.permissions.missingSessionID",
                          defaultValue: "A session scope needs session_id.")
        case .invalidProjectRoot:
            return String(localized: "socket.permissions.invalidProjectRoot",
                          defaultValue: "A project scope needs root, an absolute path to an existing directory.")
        case .invalidExpiry:
            return String(localized: "socket.permissions.invalidExpiry",
                          defaultValue: "expires_in_seconds must be between one minute and 30 days.")
        }
    }
}
