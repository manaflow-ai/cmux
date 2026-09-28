import CMUXMobileCore
import Foundation

/// The control-plane error contract used by every Cloud retry decision.
public struct CloudVMHTTPError: Error, CustomStringConvertible, Equatable, Sendable {
    public let status: Int
    public let code: String
    public let retryable: Bool
    public let retryAfterSeconds: Int?
    public let phase: String?
    public let traceId: String?
    public let displayText: String

    public init(status: Int, body: String, retryAfterHeader: String? = nil) {
        let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any] ?? [:]
        self.init(status: status, object: object, body: body, retryAfterHeader: retryAfterHeader)
    }

    private init(status: Int, object: [String: Any], body: String, retryAfterHeader: String?) {
        let ui = object["ui"] as? [String: Any]
        self.status = status
        self.code = cloudVMString(object["error"]) ?? "http_\(status)"
        self.retryable = cloudVMBool(object["retryable"]) ?? cloudVMBool(ui?["retryable"]) ?? false
        self.retryAfterSeconds = cloudVMInt(object["retryAfterSeconds"])
            ?? cloudVMInt(ui?["retryAfterSeconds"])
            ?? CmxRetryAfterPolicy().seconds(from: retryAfterHeader)
        self.phase = cloudVMString(object["phase"]) ?? cloudVMString(ui?["phase"])
        self.traceId = cloudVMString(object["traceId"])
            ?? cloudVMString(ui?["traceId"])
        self.displayText = formattedCloudVMHTTPError(status: status, object: object)
    }

    public var description: String { displayText }

    /// Both spellings have existed in the VM API during the migration from the
    /// legacy provider response. They are one terminal machine state to clients.
    public var requiresRecreate: Bool {
        status == 409 && (code == "vm_requires_recreate" || code == "vm_recreate_required")
    }

    /// A 401/403 is a rejected account session for Cloud polling purposes.
    public var rejectsSession: Bool { status == 401 || status == 403 }

    /// Only an explicit server retry or the 429 rate-limit contract admits an
    /// automatic retry. A familiar message or a 5xx status alone never does.
    public var admitsAutomaticRetry: Bool { retryable || status == 429 }
}

/// One bounded retry policy shared by request retries and every Cloud poller.
public struct CloudVMRetryPolicy: Sendable, Equatable {
    public enum Decision: Equatable, Sendable {
        case retry(delay: Duration)
        case stop
    }

    public let baseDelaySeconds: Double
    public let maximumDelaySeconds: Double
    public let maximumAttempts: Int
    public let maximumElapsedSeconds: Double

    public init(
        baseDelaySeconds: Double = 2,
        maximumDelaySeconds: Double = 60,
        maximumAttempts: Int = 6,
        maximumElapsedSeconds: Double = 5 * 60
    ) {
        self.baseDelaySeconds = max(baseDelaySeconds, 0)
        self.maximumDelaySeconds = max(maximumDelaySeconds, self.baseDelaySeconds)
        self.maximumAttempts = max(maximumAttempts, 1)
        self.maximumElapsedSeconds = max(maximumElapsedSeconds, 0)
    }

    public static let automatic = CloudVMRetryPolicy()

    /// Returns the next action for a typed server refusal. `attempt` is the
    /// number of requests already made and `elapsedSeconds` is the time spent
    /// in this automatic retry episode.
    public func decision(
        for error: CloudVMHTTPError,
        attempt: Int,
        elapsedSeconds: Double,
        jitter: Double = 0
    ) -> Decision {
        guard error.admitsAutomaticRetry,
              !error.requiresRecreate,
              !error.rejectsSession,
              attempt < maximumAttempts,
              elapsedSeconds < maximumElapsedSeconds else {
            return .stop
        }
        return .retry(delay: delay(
            afterAttempt: attempt,
            retryAfterSeconds: error.retryAfterSeconds,
            jitter: jitter
        ))
    }

    /// Exponential backoff with bounded jitter. The server-provided delay is a
    /// floor and may exceed the local cap when the service asks us to wait longer.
    public func delay(afterAttempt attempt: Int, retryAfterSeconds: Int? = nil, jitter: Double = 0) -> Duration {
        let exponent = min(max(attempt - 1, 0), 30)
        let exponential = min(baseDelaySeconds * pow(2, Double(exponent)), maximumDelaySeconds)
        let normalizedJitter = min(max(jitter, 0), 0.25)
        let localDelay = exponential * (1 + normalizedJitter)
        let serverDelay = Double(max(retryAfterSeconds ?? 0, 0))
        return .seconds(max(localDelay, serverDelay))
    }
}

/// Actor-owned callers use this value ledger to keep terminal and retryable
/// refusals sticky per machine while sharing one policy and reset seam.
public struct CloudVMRetryLedger: Sendable, Equatable {
    public enum Admission: Equatable, Sendable {
        case allowed
        case blocked(CloudVMHTTPError)
    }

    private struct Entry: Sendable, Equatable {
        let attempts: Int
        let startedAt: Date
        let retryAt: Date?
        let error: CloudVMHTTPError
    }

    private let policy: CloudVMRetryPolicy
    private var entries: [String: Entry] = [:]

    public init(policy: CloudVMRetryPolicy = .automatic) {
        self.policy = policy
    }

    public mutating func admission(machineID: String, now: Date) -> Admission {
        guard let entry = entries[machineID] else { return .allowed }
        if entry.retryAt == nil || now.timeIntervalSince(entry.startedAt) >= policy.maximumElapsedSeconds {
            return .blocked(entry.error)
        }
        if let retryAt = entry.retryAt, retryAt > now { return .blocked(entry.error) }
        return .allowed
    }

    @discardableResult
    public mutating func recordFailure(
        machineID: String,
        error: CloudVMHTTPError,
        now: Date,
        jitter: Double = 0
    ) -> CloudVMRetryPolicy.Decision {
        let previous = entries[machineID]
        let attempts = (previous?.attempts ?? 0) + 1
        let startedAt = previous?.startedAt ?? now
        let elapsed = now.timeIntervalSince(startedAt)
        let decision = policy.decision(for: error, attempt: attempts, elapsedSeconds: elapsed, jitter: jitter)
        let retryAt: Date?
        if case .retry(let delay) = decision {
            let components = delay.components
            let seconds = Double(components.seconds) + Double(components.attoseconds) / 1_000_000_000_000_000_000
            retryAt = now.addingTimeInterval(seconds)
        } else {
            retryAt = nil
        }
        entries[machineID] = Entry(attempts: attempts, startedAt: startedAt, retryAt: retryAt, error: error)
        return decision
    }

    public mutating func recordSuccess(machineID: String) {
        entries.removeValue(forKey: machineID)
    }

    public mutating func reset(machineID: String) {
        recordSuccess(machineID: machineID)
    }

    public mutating func removeAll() {
        entries.removeAll()
    }
}

public func formattedCloudVMHTTPError(status: Int, body: String) -> String {
    let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let data = trimmedBody.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return """
            Cloud VM request failed (HTTP \(status)).

            What to do:
              Retry the command. If it keeps failing, copy the HTTP status and contact support.

            Response body:
              <unreadable response omitted>
            """
    }
    return formattedCloudVMHTTPError(status: status, object: object)
}

private func formattedCloudVMHTTPError(status: Int, object: [String: Any]) -> String {
    let errorCode = cloudVMString(object["error"]) ?? "http_\(status)"
    let ui = object["ui"] as? [String: Any]
    let message = defaultCloudVMMessage(status: status, errorCode: errorCode)
    let action = defaultCloudVMAction(status: status, errorCode: errorCode, response: object)
    let retryAfterSeconds = cloudVMInt(object["retryAfterSeconds"])
        ?? cloudVMInt(ui?["retryAfterSeconds"])
    let retryable = cloudVMBool(object["retryable"]) ?? cloudVMBool(ui?["retryable"]) ?? status == 429

    var lines: [String] = [
        "Cloud VM request failed (HTTP \(status))",
        message,
    ]
    if retryable, let retryAfterSeconds, retryAfterSeconds > 0 {
        lines.append("Retrying is safe. Next automatic retry is in about \(retryAfterSeconds)s when this request is part of an attach loop.")
    }
    if !action.isEmpty {
        lines.append("")
        lines.append("What to do:")
        lines.append("  \(action)")
    }
    return lines.joined(separator: "\n")
}

public func cloudVMReferenceLine(traceId: String) -> String {
    String(format: String(localized: "cloudVM.error.reference", defaultValue: "Reference: %@"), traceId)
}

private func defaultCloudVMMessage(status: Int, errorCode: String) -> String {
    switch errorCode {
    case "vm_requires_recreate", "vm_recreate_required":
        return String(
            localized: "cloudVM.error.recreateRequired.message",
            defaultValue: "This Cloud machine can no longer be attached. Recreate it to continue."
        )
    default:
        switch status {
        case 400: return "The Cloud VM request was not valid."
        case 401: return "cmux could not authenticate this Cloud VM request."
        case 402: return "This team cannot create another Cloud VM with the current billing state."
        case 403: return "This Cloud VM request was not allowed."
        case 404: return "The requested Cloud VM was not found."
        case 409: return "Another Cloud VM operation is already running."
        case 500...599: return "The Cloud VM service is temporarily unavailable."
        default: return "The Cloud VM service returned an error."
        }
    }
}

public func defaultCloudVMAction(status: Int, errorCode: String, response: [String: Any] = [:]) -> String {
    switch errorCode {
    case "vm_requires_recreate", "vm_recreate_required":
        return String(
            localized: "cloudVM.error.recreateRequired.action",
            defaultValue: "Recreate this machine, then open the new machine."
        )
    case "vm_active_limit_exceeded":
        return "Run `cmux vm ls`, then stop or delete an active VM with `cmux vm rm <id>` before retrying."
    case "vm_not_found":
        return "Run `cmux vm ls` to see available Cloud VMs. If the VM was paused or destroyed, start a fresh one with `cmux vm new`."
    case "vm_billing_team_required":
        return "Select a team in cmux, then retry. You can also run `cmux auth status` to check the signed-in account."
    case "vm_requires_pro":
        return String(localized: "cloudVM.error.requiresPro.action", defaultValue: "Upgrade to cmux Pro at https://cmux.com/pricing?cmux_source=mac_vm_requires_pro_error&cmux_client=mac to create Cloud VMs.")
    case "vm_memory_requires_plan":
        let details = response["details"] as? [String: Any]
        let planId = cloudVMString(response["upgradePlanId"]) ?? cloudVMString(details?["upgradePlanId"]) ?? "max"
        let plan: CheckoutPlan = planId == CheckoutPlan.pro.rawValue ? .pro : .max
        let checkout = CheckoutAttribution.checkoutURL(source: .vmMemoryRequiresPlanError, plan: plan)
        if plan == .pro {
            return String(format: String(localized: "cloudVM.error.memoryRequiresPlan.proAction", defaultValue: "Larger machines need cmux Pro. Upgrade at %@, or choose a smaller machine."), checkout.absoluteString)
        }
        return String(format: String(localized: "cloudVM.error.memoryRequiresPlan.action", defaultValue: "Larger machines need cmux Max. Upgrade at %@, or choose a smaller machine."), checkout.absoluteString)
    case "vm_create_credits_insufficient":
        return "Ask a team admin to upgrade the plan or grant more Cloud VM create credits, then retry."
    default:
        if status == 401 { return "Run `cmux auth login`, then retry." }
        if status == 403 { return "Run `cmux auth status` and confirm you are using the expected team." }
        return "Retry the command. If it keeps failing, copy this error and contact support."
    }
}

func cloudVMString(_ value: Any?) -> String? {
    guard let string = value as? String else { return nil }
    let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

func cloudVMInt(_ value: Any?) -> Int? {
    if let int = value as? Int { return int }
    if let double = value as? Double, double.isFinite { return Int(double) }
    if let number = value as? NSNumber { return number.intValue }
    if let string = value as? String { return Int(string.trimmingCharacters(in: .whitespacesAndNewlines)) }
    return nil
}

private func cloudVMBool(_ value: Any?) -> Bool? {
    if let bool = value as? Bool { return bool }
    if let number = value as? NSNumber { return number.boolValue }
    if let string = value as? String { return Bool(string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) }
    return nil
}

func cloudVMIsNull(_ value: Any) -> Bool { value is NSNull }
