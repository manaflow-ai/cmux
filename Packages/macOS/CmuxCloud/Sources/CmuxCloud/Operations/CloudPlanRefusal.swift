import CmuxCloudResizeCore
import Foundation

/// A `402` the control plane explained with a stable `error` code, read so a
/// person sees what actually stopped the request instead of a status-only
/// "your plan does not allow this" sentence. The server enforces every limit;
/// this type only names the one it reported.
public struct CloudPlanRefusal: Equatable, Sendable {
    /// What the server refused, from its `error` code.
    public enum Kind: Equatable, Sendable {
        /// `vm_resource_pool_exceeded`: running machines already hold the
        /// team's shared vCPUs or memory. Carries the overflow when the answer
        /// named the pool, what is in use, and the request.
        case resourcePool(CloudVMResourcePool.Shortfall?)
        /// `vm_active_limit_exceeded` with a nonzero limit: every active slot is taken.
        case activeLimit
        /// `vm_create_credits_insufficient`.
        case createCredits
        /// `vm_memory_requires_plan`: the size needs a larger plan.
        case memoryRequiresPlan
        /// Any other code; the server's own message explains it.
        case other
    }

    /// The server's `error` code.
    public let code: String
    public let kind: Kind
    /// The server's one-line explanation (`ui.message`, else `message`).
    public let serverMessage: String?
    /// The plan the answer offers as an upgrade (`upgradePlanId`), if any.
    public let upgradePlanId: String?

    /// Reads a `402` answer; nil for other statuses or a body without a code.
    /// - Parameters:
    ///   - status: The HTTP status.
    ///   - body: The response body.
    public init?(status: Int, body: String) {
        guard status == 402,
              let data = body.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let code = Self.string(object["error"]) else { return nil }
        let ui = object["ui"] as? [String: Any]
        self.code = code
        self.serverMessage = Self.string(ui?["message"]) ?? Self.string(object["message"])
        self.upgradePlanId = Self.string(object["upgradePlanId"])
        switch code {
        case Self.resourcePoolExceededCode:
            kind = .resourcePool(Self.shortfall(object))
        case Self.activeLimitExceededCode:
            // A zero limit is the subscribe gate, not a full set of slots.
            let limit = (object["limit"] as? NSNumber)?.intValue
            kind = limit == 0 ? .other : .activeLimit
        case "vm_create_credits_insufficient":
            kind = .createCredits
        case "vm_memory_requires_plan":
            kind = .memoryRequiresPlan
        default:
            kind = .other
        }
    }

    /// Reads the refusal from a Cloud client error; nil for anything else.
    /// - Parameter error: The thrown error.
    public init?(_ error: Error) {
        if case let .httpStatus(status, body)? = error as? VMClientError {
            self.init(status: status, body: body)
        } else if case let .httpStatus(status, body)? = error as? MachineUsageClientError {
            self.init(status: status, body: body)
        } else {
            return nil
        }
    }

    /// The diagnostic class: a full pool or full set of active slots is a
    /// limit the team's own machines hold; the rest is what the plan includes.
    /// Only classes the telemetry contract accepts may be returned here.
    public var diagnosticFailure: CloudDiagnosticFailure {
        switch kind {
        case .resourcePool, .activeLimit: return .resourceLimit
        case .createCredits, .memoryRequiresPlan, .other: return .plan
        }
    }

    /// Whether the answer names a larger plan that would let the request through.
    public var offersUpgrade: Bool { upgradePlanId != nil }

    /// Whether a failed-create row can offer a larger plan for this refusal.
    ///
    /// - Parameters:
    ///   - code: The refusal code carried by the failed create.
    ///   - plan: The currently loaded plan, or nil while it is unavailable.
    /// - Returns: Whether the row should show its upgrade action.
    public static func offersUpgrade(for code: String?, plan: MachinePlanSnapshot?) -> Bool {
        if code == activeLimitExceededCode { return plan?.hasHigherPlan ?? true }
        return code == resourcePoolExceededCode && plan?.hasHigherResourcePoolPlan == true
    }

    /// The localized sentence for a person: what stopped the request and what
    /// to do, with an upgrade only as the secondary option.
    public var message: String {
        switch kind {
        case .resourcePool(let shortfall?):
            return CloudVMResourcePool.shortfallText(shortfall, offersUpgrade: offersUpgrade)
        case .resourcePool(nil):
            return Self.capacityMessage
        case .activeLimit:
            return String(
                localized: "cloud.operation.failure.activeLimit",
                defaultValue: "Every active machine your plan allows is in use. Pause or delete a running machine, then try again."
            )
        case .createCredits:
            if serverMessage?.hasPrefix("Your account has no Cloud VM create credits left.") == true {
                return String(
                    localized: "cloud.operation.failure.createCredits.account",
                    defaultValue: "Your account has no machine create credits left. Add Cloud VM create credits or upgrade your plan."
                )
            }
            return String(
                localized: "cloud.operation.failure.createCredits",
                defaultValue: "Your team has no machine create credits left. Ask a team admin to add credits or upgrade the plan."
            )
        case .memoryRequiresPlan:
            return String(
                localized: "cloud.operation.failure.memoryRequiresPlan",
                defaultValue: "This size is larger than your plan includes. Choose a smaller size, or upgrade the plan."
            )
        case .other:
            return serverMessage ?? CloudDiagnosticFailure.plan.label
        }
    }

    /// `vm_resource_pool_exceeded`: running machines hold the shared pool.
    public static let resourcePoolExceededCode = "vm_resource_pool_exceeded"
    /// `vm_active_limit_exceeded`: every active-machine slot is taken.
    public static let activeLimitExceededCode = "vm_active_limit_exceeded"

    /// The stable reference a failure transcript carries for a refusal, as
    /// both the CLI and the in-process create print it.
    /// - Parameter code: The server's `error` code.
    public static func reference(code: String) -> String { "(HTTP 402: \(code))" }

    /// The refusal code the `cmux` CLI named in its own error header, the
    /// `Error: <title> (HTTP 402: <code>)` line it writes when a request
    /// fails; nil when the transcript has no such header. Only the first
    /// `Error:` line is read and only the reference that ends it, so the
    /// server's message on the lines after it can never stand in for the code.
    /// - Parameter output: The CLI's failure transcript.
    public static func code(inCLIFailureOutput output: String) -> String? {
        guard let header = output.split(whereSeparator: \.isNewline)
            .first(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("Error:") }) else { return nil }
        let line = header.trimmingCharacters(in: .whitespaces)
        guard let match = line.range(of: #"\(HTTP 402: [A-Za-z0-9_.-]+\)$"#, options: .regularExpression) else {
            return nil
        }
        return String(line[match].dropFirst("(HTTP 402: ".count).dropLast())
    }

    /// A full pool whose answer did not name the numbers.
    public static var capacityMessage: String {
        String(
            localized: "cloud.operation.failure.capacity",
            defaultValue: "Your team's running machines are using all of the plan's Cloud capacity. Pause or delete a running machine, then try again."
        )
    }

    /// The overflow named by a pool answer's `resource`, `pool`, `used`, and
    /// `requested`; nil when any part is missing.
    private static func shortfall(_ object: [String: Any]) -> CloudVMResourcePool.Shortfall? {
        guard let pool = object["pool"] as? [String: Any],
              let used = object["used"] as? [String: Any],
              let requested = object["requested"] as? [String: Any] else { return nil }
        switch string(object["resource"]) {
        case "memoryMb":
            guard let poolMb = int(pool["memoryMb"]), let usedMb = int(used["memoryMb"]),
                  let requestedMb = int(requested["memoryMb"]) else { return nil }
            return .memory(requestedMb: requestedMb, freeMb: max(0, poolMb - usedMb), poolMb: poolMb)
        case "vcpus":
            guard let poolVcpus = int(pool["vcpus"]), let usedVcpus = int(used["vcpus"]),
                  let requestedVcpus = int(requested["vcpus"]) else { return nil }
            return .vcpus(requested: requestedVcpus, free: max(0, poolVcpus - usedVcpus), pool: poolVcpus)
        default:
            return nil
        }
    }

    private static func string(_ raw: Any?) -> String? {
        guard let value = (raw as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }

    private static func int(_ raw: Any?) -> Int? {
        guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue >= 0 else { return nil }
        return Int(exactly: number.doubleValue)
    }
}
