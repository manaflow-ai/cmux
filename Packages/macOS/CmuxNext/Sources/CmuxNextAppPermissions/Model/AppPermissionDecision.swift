public import CmuxNextApps
import Foundation

/// The answer of `AppPermissionPolicy.effectiveDecision` for one call.
public nonisolated enum AppPermissionDecision: Sendable, Hashable {
    /// Runs now.
    case allow
    /// Waits for the user (host-drawn prompt, 2 min deadline).
    case ask(AppApprovalPrompt, scope: String)
    /// Refused; the app gets `refusal.error`.
    case refuse(AppRefusal)

    /// 3 = runs, 2 = asks once per session, 1 = asks for this call, 0 =
    /// refused. A grant change that narrows never raises it.
    public var permissiveness: Int {
        switch self {
        case .allow: 3
        case .ask(.perSession, _): 2
        case .ask(.perCall, _), .ask(.firstUse, _): 1
        case .refuse: 0
        }
    }

    public var isAllowed: Bool { self == .allow }
    public var refusal: AppRefusal? { if case .refuse(let r) = self { r } else { nil } }
}

/// Which prompt the host shows.
public nonisolated enum AppApprovalPrompt: String, Sendable, Hashable, Codable {
    /// Approval `per_session`: one answer covers the rest of the session.
    case perSession
    /// Approval `per_call`: this call only.
    case perCall
    /// An optional scope the app has never been granted: inline prompt
    /// with Allow once / Allow / Deny.
    case firstUse
}

/// Why a call is refused, and the error the app receives.
public nonisolated struct AppRefusal: Sendable, Hashable {
    public enum Reason: String, Sendable, Hashable, Codable {
        /// The grant does not hold the scope (or it is off).
        case scopeMissing
        /// The scope is held but outside the selected workspaces, rooms,
        /// machines or file roots.
        case outsideResources
        /// The sandbox profile does not allow the scope.
        case profile
        /// The app's tier may not hold this restricted scope.
        case tierRestricted
        /// No app may ever call this op (spec 6.5 "never").
        case never
        /// The op is not in the public scope table.
        case unsupported
        /// Params do not name what the scope needs (`net.fetch` without an https URL).
        case invalidParams
        /// The grant narrowed after the call was made.
        case revoked
        /// "Revoke all and disable".
        case disabled
    }

    public var reason: Reason
    public var op: String
    /// The scope the call needs, when known.
    public var scope: String?

    public init(reason: Reason, op: String, scope: String? = nil) {
        self.reason = reason
        self.op = op
        self.scope = scope
    }

    /// The error the app sees. Every grant-shaped refusal is
    /// `scope.missing` so an app handles one code (section 5.2); `details.reason`
    /// says which layer refused.
    public var error: AppOperationError {
        var details: [String: AppJSON] = ["op": .string(op), "reason": .string(reason.rawValue)]
        if let scope { details["scope"] = .string(scope) }
        let code: String = switch reason {
        case .never: "operation.forbidden"
        case .unsupported: "operation.unsupported"
        case .invalidParams: "invalid_params"
        case .revoked: "grant.revoked"
        case .scopeMissing, .outsideResources, .profile, .tierRestricted, .disabled: "scope.missing"
        }
        return AppOperationError(code: code, message: "\(op) refused: \(reason.rawValue)", details: .object(details),
                                 retryable: reason == .revoked)
    }
}

