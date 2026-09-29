import CmuxAuthRuntime
import CmuxCloudMachines
import Foundation

/// ``VMClient``'s retry state for `POST /api/vm/tunnel`, keyed per login.
///
/// Every tunnel enrollment funnels through `VMClient.enrollTunnel`, so this is
/// the one place that can stop a permanent refusal from becoming a request
/// loop, whichever caller (WireGuard hub startup, browser Network Extension,
/// `cmux vpn up`) retries. A refused login answers the stored error without a
/// request until ``CloudTunnelEnrollmentGate`` lets the next one through; a
/// revoked login never does, and a new sign-in is a new key.
struct VMTunnelEnrollmentGuard {
    private var gate = CloudTunnelEnrollmentGate()
    private var lastFailure: [String: VMClientError] = [:]

    /// One login: the account plus the session generation that a sign-in
    /// advances. nil (signed out) is never gated; the request fails locally.
    static func key(for identity: AuthenticatedSessionIdentity?) -> String? {
        identity.map { "\($0.accountID)|\($0.generation)" }
    }

    /// Throws the stored refusal when `key` may not send a request yet.
    func admit(_ key: String?, now: Date = Date()) throws {
        guard let key, gate.blockedUntil(key, now: now) != nil, let stored = lastFailure[key] else { return }
        throw stored
    }

    /// Only answers the control plane (or its absence) produced gate a login;
    /// local refusals (signed out, Cloud disabled) never sent a request.
    mutating func recordFailure(_ error: VMClientError, key: String?, now: Date = Date()) {
        guard let key, let failure = error.tunnelEnrollmentFailure else { return }
        gate.recordFailure(key, failure, now: now)
        lastFailure[key] = error
    }

    mutating func recordSuccess(_ key: String?) {
        guard let key else { return }
        gate.recordSuccess(key)
        lastFailure[key] = nil
    }

    func isAccessRevoked(_ key: String?) -> Bool {
        guard let key else { return false }
        return gate.isAccessRevoked(key)
    }
}

extension VMClientError {
    /// How the tunnel gate treats this error; nil for local refusals.
    var tunnelEnrollmentFailure: CloudTunnelEnrollmentGate.Failure? {
        switch self {
        case .httpStatus(let status, let body):
            return CloudTunnelEnrollmentGate.classify(status: status, body: Data(body.utf8))
        case .backendUnreachable, .malformedResponse:
            return .init(kind: .retryable)
        case .notSignedIn, .sessionRefreshFailed, .disabledByManagedPolicy, .cloudMachinesDisabled, .lifecycleUnsupported:
            return nil
        }
    }

    /// True when an immediate retry of the enrollment gets the same answer.
    public var isPermanentCloudTunnelRefusal: Bool {
        tunnelEnrollmentFailure?.kind.isPermanent ?? false
    }

    /// True when the server revoked Cloud access for this Mac login
    /// (`vm_access_revoked`); only signing in again can enroll this Mac.
    public var isCloudAccessRevoked: Bool {
        tunnelEnrollmentFailure?.kind == .accessRevoked
    }
}

/// The app's own copy for `vm_access_revoked`, in the app's language, so the
/// sidebar, the Machines panel and `cmux vpn up` all name the one fix.
func cloudVMAccessRevokedDescription(status: Int, response: [String: Any]) -> String? {
    guard response["error"] as? String == CloudTunnelEnrollmentGate.accessRevokedErrorCode else { return nil }
    var lines = [
        "\(cloudVMAccessRevokedTitle()) (HTTP \(status): \(CloudTunnelEnrollmentGate.accessRevokedErrorCode))",
        cloudVMAccessRevokedMessage(),
        "",
        String(localized: "cloudVM.error.accessRevoked.whatToDo", defaultValue: "What to do:"),
        "  " + cloudVMAccessRevokedAction(),
    ]
    let ui = response["ui"] as? [String: Any]
    if let traceId = (response["traceId"] as? String) ?? (ui?["traceId"] as? String), !traceId.isEmpty {
        lines.append("")
        lines.append(cloudVMReferenceLine(traceId: traceId))
    }
    return lines.joined(separator: "\n")
}

/// Title for a Mac login whose Cloud access was revoked (`vm_access_revoked`).
public func cloudVMAccessRevokedTitle() -> String {
    String(localized: "cloudVM.error.accessRevoked.title", defaultValue: "Cloud access for this Mac was revoked")
}

/// One-line state for a revoked Mac login.
public func cloudVMAccessRevokedMessage() -> String {
    String(
        localized: "cloudVM.error.accessRevoked.message",
        defaultValue: "This Mac’s cmux login can no longer reach your Cloud machines. Retrying will not fix it."
    )
}

/// The one fix for `vm_access_revoked`.
public func cloudVMAccessRevokedAction() -> String {
    String(
        localized: "cloudVM.error.accessRevoked.action",
        defaultValue: "Sign out of cmux, then sign in again. The new sign-in enrolls this Mac again."
    )
}
