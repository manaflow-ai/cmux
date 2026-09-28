import CMUXAgentLaunch
import Foundation

/// Socket v2 surface for batch agent permission grants.
///
/// The app is the only authority: it holds approved grants in memory
/// (``AgentPermissionGrantRegistry``, loaded from its own store at launch),
/// adds them only when the user clicks Approve in the panel, and answers
/// `permissions.match` for the `PermissionRequest` hook with allow or no
/// match, never grant contents. `permissions.request` is only a proposal.
/// All four methods run on the socket worker; only the panel itself runs on
/// the main actor, and it doesn't activate the app. None of them is
/// permitted through a remote relay.
extension TerminalController {
    /// How long `permissions.request` waits for the user before denying.
    /// Under Claude Code's two-minute Bash timeout, so the waiting
    /// `cmux permissions request` finishes first.
    nonisolated static let permissionRequestTimeoutSeconds: TimeInterval = 100

    nonisolated static let permissionGrantRegistry = AgentPermissionGrantRegistry(
        store: AgentPermissionGrantStore(fileURL: AgentPermissionGrantStore.defaultFileURL())
    )

    /// Loads approved grants off the main actor when the socket starts.
    nonisolated static func loadPermissionGrants() {
        Task.detached(priority: .utility) { _ = TerminalController.permissionGrantRegistry }
    }

    // MARK: permissions.match

    /// Allow or no match for one pending tool call. A match counts a use.
    nonisolated func v2PermissionsMatch(params: [String: Any]) -> V2CallResult {
        .ok(["allow": Self.permissionGrantRegistry.answer(matchParams: params)])
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
        let registry = Self.permissionGrantRegistry
        guard registry.beginApproval() else {
            return .err(
                code: "busy",
                message: String(
                    localized: "socket.permissions.busy",
                    defaultValue: "Another permission request is waiting for an answer."
                ),
                data: nil
            )
        }
        defer { registry.endApproval() }
        let decision = await AgentPermissionGrantApprovalPanel.requestDecision(for: proposal)
        // A request that timed out while the user clicked grants nothing.
        guard !Task.isCancelled,
              case .approved(let selected) = decision,
              let grant = proposal.grant(approving: selected, now: Date()) else {
            return .ok(["denied": true])
        }
        do {
            try registry.add(grant)
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
        .ok(["grants": Self.permissionGrantRegistry.activeGrants().map(\.socketPayload)])
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
            let revoked = try Self.permissionGrantRegistry.revoke(id: id)
            return .ok(["revoked": revoked])
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
        case .invalidReason:
            return String(localized: "socket.permissions.invalidReason",
                          defaultValue: "reason must not contain control or invisible formatting characters.")
        }
    }
}
