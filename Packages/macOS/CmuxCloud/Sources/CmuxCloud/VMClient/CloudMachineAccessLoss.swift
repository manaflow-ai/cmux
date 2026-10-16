import Foundation

/// Classifies control-plane answers that mean the signed-in user can no longer
/// reach a Cloud machine.
///
/// A permanent loss ends automatic reconnects: retrying cannot succeed until
/// the user regains access, and a pane that keeps retrying would only show a
/// frozen frame. Transient failures (timeouts, 5xx, throttling, transport
/// errors) are never permanent, and neither is a 403 that answers for a team,
/// a plan or this Mac's network enrollment rather than for the machine.
///
/// ```swift
/// if let loss = CloudMachineAccessLoss(error: error) {
///     provider.noteAccessLost(loss)
/// }
/// ```
public enum CloudMachineAccessLoss: Equatable, Sendable {
    /// The machine no longer exists for this user (`404 vm_not_found`).
    case notFound
    /// The user is no longer allowed to use the machine (`403`), including
    /// removal from the machine's team.
    case forbidden
    /// The machine belongs to an owner the request is not authorized for
    /// (`vm_owner_mismatch`, any status).
    case ownerMismatch
    /// The Cloud access granted to this Mac login was revoked
    /// (`403 vm_access_revoked`), typically by a sign-out on this Mac. It
    /// covers every machine and ends only with a new sign-in.
    case signInRevoked

    /// 403 codes that refuse a team, a plan or a token rather than the
    /// machine. They never prove the user lost the machine; a team list that
    /// was incomplete for one request can answer `vm_billing_team_not_found`
    /// for a team the user still belongs to.
    static let nonMachineForbiddenCodes: Set<String> = [
        "vm_billing_team_not_found",
        "vm_billing_team_required",
        "vm_resize_plan_limit",
        "vm_bound_token_required",
    ]

    /// Whether the answer is about this machine alone. A later authorized
    /// read of the machine disproves a machine-scoped loss; it says nothing
    /// about a revoked sign-in.
    public var isMachineScoped: Bool { self != .signInRevoked }

    /// Classifies `error`; nil when it is not a permanent access loss.
    ///
    /// - Parameter error: An error thrown by ``VMClient``.
    public init?(error: Error) {
        guard case let VMClientError.httpStatus(status, body) = error else { return nil }
        self.init(status: status, body: body)
    }

    /// Classifies an HTTP status and response body; nil when transient.
    ///
    /// - Parameters:
    ///   - status: The HTTP status code.
    ///   - body: The response body, whose JSON `error` field carries the code.
    public init?(status: Int, body: String) {
        let object = Self.errorObject(body)
        let code = Self.string(object?["error"])
        if code == "vm_owner_mismatch" {
            self = .ownerMismatch
        } else if status == 403, code == "vm_access_revoked" {
            self = .signInRevoked
        } else if status == 403 {
            // A network-phase refusal is about this Mac's enrollment, never
            // about one machine.
            if let code, Self.nonMachineForbiddenCodes.contains(code) { return nil }
            if Self.string(object?["phase"]) == "network" { return nil }
            self = .forbidden
        } else if status == 404, code == "vm_not_found" {
            self = .notFound
        } else {
            return nil
        }
    }

    private static func errorObject(_ body: String) -> [String: Any]? {
        guard let data = body.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func string(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
