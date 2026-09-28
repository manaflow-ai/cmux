import Foundation

/// Decides when the app may send another attach request for one Cloud machine
/// after the control plane refused the previous one.
///
/// Every in-app caller (the link manager, the browser carrier, the socket verb
/// behind `cmux vm tui`) funnels through `VMClient.openCmuxRemote`, which owns
/// one gate. Callers may poll as often as they like; the gate turns repeated
/// failures into at most one request per window:
///
/// - `vm_recreate_required` is permanent machine state. The gate holds it for
///   ``recreateRequiredHold`` and answers the stored error without a request,
///   so the only traffic left is a rare recheck in case an operator repairs
///   the row.
/// - Any other refusal backs off exponentially from ``baseDelay`` to
///   ``maxDelay``, and never retries sooner than the server's `retryAfterSeconds`.
///
/// A success clears the machine's entry.
public struct CloudAttachRetryGate: Sendable {
    public enum FailureKind: Sendable, Equatable {
        /// The machine can never attach; the user must delete and recreate it.
        case recreateRequired
        /// Anything else; retry with bounded exponential backoff.
        case retryable
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

    public static let recreateRequiredErrorCode = "vm_recreate_required"

    public let baseDelay: TimeInterval
    public let maxDelay: TimeInterval
    public let recreateRequiredHold: TimeInterval
    private var entries: [String: Entry] = [:]

    private struct Entry: Sendable {
        var consecutiveFailures: Int
        var notBefore: Date
    }

    public init(baseDelay: TimeInterval = 2, maxDelay: TimeInterval = 60, recreateRequiredHold: TimeInterval = 30 * 60) {
        self.baseDelay = baseDelay
        self.maxDelay = max(maxDelay, baseDelay)
        self.recreateRequiredHold = recreateRequiredHold
    }

    /// Classifies a non-2xx VM API answer from its status and JSON body.
    public static func classify(status: Int, body: Data) -> Failure {
        let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let code = object?["error"] as? String
        if code == recreateRequiredErrorCode {
            return Failure(kind: .recreateRequired)
        }
        let ui = object?["ui"] as? [String: Any]
        return Failure(kind: .retryable, retryAfterSeconds: seconds(object?["retryAfterSeconds"]) ?? seconds(ui?["retryAfterSeconds"]))
    }

    /// True when the body is the permanent recreate-required answer.
    public static func isRecreateRequired(status: Int, body: Data) -> Bool {
        classify(status: status, body: body).kind == .recreateRequired
    }

    /// The instant before which `key` must not send another request, or nil when it may.
    public func blockedUntil(_ key: String, now: Date) -> Date? {
        guard let entry = entries[key], entry.notBefore > now else { return nil }
        return entry.notBefore
    }

    /// Records a refusal and returns when the next request for `key` may go out.
    @discardableResult
    public mutating func recordFailure(_ key: String, _ failure: Failure, now: Date) -> Date {
        let failures = (entries[key]?.consecutiveFailures ?? 0) + 1
        let delay: TimeInterval
        switch failure.kind {
        case .recreateRequired:
            delay = recreateRequiredHold
        case .retryable:
            delay = max(backoff(afterFailures: failures), TimeInterval(max(failure.retryAfterSeconds ?? 0, 0)))
        }
        let notBefore = now.addingTimeInterval(delay)
        entries[key] = Entry(consecutiveFailures: failures, notBefore: notBefore)
        return notBefore
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
