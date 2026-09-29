import Foundation

/// Decides when the app may send another `POST /api/vm/tunnel` for one login
/// after the control plane refused the previous one.
///
/// Every enrollment (the WireGuard hub, the browser Network Extension, the
/// `cmux vpn up` socket verb) funnels through `VMClient.enrollTunnel`, which
/// owns one gate keyed by account and session generation. Callers may retry as
/// often as they like; the gate answers the stored refusal without a request:
///
/// - `vm_access_revoked` is permanent for this login. Only a new sign-in, which
///   starts a new session generation and so a new key, can enroll again.
/// - Any other explicit or 4xx refusal the server marks non-retryable is held
///   for ``notRetryableHold``.
/// - Everything else backs off exponentially from ``baseDelay`` to
///   ``maxDelay``, and never sooner than the server's `retryAfterSeconds`.
///
/// A success clears the login's entry. The backoff arithmetic matches the
/// attach gate for Cloud machines, so both paths pace a failing control plane
/// the same way.
public struct CloudTunnelEnrollmentGate: Sendable {
    public enum FailureKind: Sendable, Equatable {
        /// The server revoked this Mac login's Cloud access; sign in again.
        case accessRevoked
        /// The server said retrying this request cannot help.
        case notRetryable
        /// Anything else; retry with bounded exponential backoff.
        case retryable

        /// True when an immediate retry is known to get the same answer.
        public var isPermanent: Bool { self != .retryable }
    }

    /// One classified control-plane refusal.
    public struct Failure: Sendable, Equatable {
        public let kind: FailureKind
        public let retryAfterSeconds: Int?

        public init(kind: FailureKind, retryAfterSeconds: Int? = nil) {
            self.kind = kind
            self.retryAfterSeconds = retryAfterSeconds
        }
    }

    public static let accessRevokedErrorCode = "vm_access_revoked"

    public let baseDelay: TimeInterval
    public let maxDelay: TimeInterval
    public let notRetryableHold: TimeInterval
    private var entries: [String: Entry] = [:]

    private struct Entry: Sendable {
        var consecutiveFailures: Int
        var kind: FailureKind
        /// nil holds until the key itself changes (a new login).
        var notBefore: Date?
    }

    public init(baseDelay: TimeInterval = 2, maxDelay: TimeInterval = 60, notRetryableHold: TimeInterval = 30 * 60) {
        self.baseDelay = baseDelay
        self.maxDelay = max(maxDelay, baseDelay)
        self.notRetryableHold = notRetryableHold
    }

    /// Classifies a non-2xx `/api/vm/tunnel` answer from its status and JSON body.
    public static func classify(status: Int, body: Data) -> Failure {
        let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        if object?["error"] as? String == accessRevokedErrorCode {
            return Failure(kind: .accessRevoked)
        }
        let ui = object?["ui"] as? [String: Any]
        let retryAfter = seconds(object?["retryAfterSeconds"]) ?? seconds(ui?["retryAfterSeconds"])
        let explicit = object?["retryable"] as? Bool
        // Transport-shaped statuses stay retryable even when a generic handler
        // omitted the flag. 401 belongs to the auth layer, which refreshes the
        // session; one stale token must not lock the login out.
        let transient = status >= 500 || [401, 408, 425, 429].contains(status)
        if explicit == true || (ui?["retryable"] as? Bool) == true || (transient && explicit != false) {
            return Failure(kind: .retryable, retryAfterSeconds: retryAfter)
        }
        // The server's `ui.retryable` defaults to false for every refusal, so
        // only a 4xx (request or account state) or an explicit top-level
        // `retryable: false` counts as a refusal a retry cannot change.
        if explicit == false || (400..<500).contains(status) {
            return Failure(kind: .notRetryable)
        }
        return Failure(kind: .retryable, retryAfterSeconds: retryAfter)
    }

    /// The instant before which `key` must not send another request, or nil
    /// when it may. A revoked login answers `.distantFuture`.
    public func blockedUntil(_ key: String, now: Date) -> Date? {
        guard let entry = entries[key] else { return nil }
        guard let notBefore = entry.notBefore else { return .distantFuture }
        return notBefore > now ? notBefore : nil
    }

    /// True once the server revoked Cloud access for the login `key` names.
    public func isAccessRevoked(_ key: String) -> Bool {
        entries[key]?.kind == .accessRevoked
    }

    /// Records a refusal and returns when the next request for `key` may go out.
    @discardableResult
    public mutating func recordFailure(_ key: String, _ failure: Failure, now: Date) -> Date {
        let failures = (entries[key]?.consecutiveFailures ?? 0) + 1
        let notBefore: Date?
        switch failure.kind {
        case .accessRevoked:
            notBefore = nil
        case .notRetryable:
            notBefore = now.addingTimeInterval(notRetryableHold)
        case .retryable:
            let delay = max(backoff(afterFailures: failures), TimeInterval(max(failure.retryAfterSeconds ?? 0, 0)))
            notBefore = now.addingTimeInterval(delay)
        }
        entries[key] = Entry(consecutiveFailures: failures, kind: failure.kind, notBefore: notBefore)
        return notBefore ?? .distantFuture
    }

    public mutating func recordSuccess(_ key: String) {
        entries[key] = nil
    }

    public mutating func removeAll() {
        entries.removeAll()
    }

    /// `baseDelay * 2^(failures - 1)`, capped at `maxDelay`.
    public func backoff(afterFailures failures: Int) -> TimeInterval {
        guard failures > 0 else { return 0 }
        let exponent = min(failures - 1, 30)
        return min(baseDelay * pow(2, Double(exponent)), maxDelay)
    }

    private static func seconds(_ value: Any?) -> Int? {
        if let int = value as? Int { return int }
        if let double = value as? Double, double.isFinite { return Int(double) }
        return nil
    }
}
