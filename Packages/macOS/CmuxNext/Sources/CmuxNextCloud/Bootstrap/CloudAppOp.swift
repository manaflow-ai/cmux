public import CmuxNextDaemon
public import Foundation

/// Cloud ops through the Cloud app server (`cmux/cloud`, contract 2.1):
/// `apps-run` on the local daemon; the server checks the args and origin,
/// keeps the machine projection, and reaches the cmux-next API Worker
/// through the host credential relay (install token, `CloudCredentialProvider`).
/// Never `/api/vm`.
/// A `LocalizedError`: a create's failure (the environment ensure) reads as this sentence, not "Something went wrong."
public nonisolated struct CloudAppOpFailure: LocalizedError, Equatable, Sendable, CustomStringConvertible {
    /// The server's code (`cmux.cloud.<reason>`).
    public var code: String
    public var message: String
    public var details: JSONValue?
    /// The server's `retryable`: the same op may answer when asked again (a backend blip,
    /// `owner.unreachable`, a busy relay). Reads use it to ask again quietly.
    public var retryable: Bool

    public static let approvalPending = "cmux.cloud.approval_pending"
    /// The op needs a paid plan (`cloud.plan.required`).
    public static let planRequired = "cmux.cloud.plan_required"

    public init(code: String, message: String, details: JSONValue? = nil, retryable: Bool = false) {
        self.code = code
        self.message = message
        self.details = details
        self.retryable = retryable
    }

    /// The approval request id (`apr_…`) of an approval code.
    public var approvalRequest: String? { details?["request"]?.stringValue }
    /// `code: message` of a pending answer's `details.last_run_error`: the backend's refusal of the approved
    /// run that sent it back to pending (cmux-platform#2180), or nil when it has none.
    public var lastRunError: String? {
        guard let last = details?["last_run_error"] else { return nil }
        let code = last["code"]?.stringValue ?? "", message = last["message"]?.stringValue ?? ""
        let text = code.isEmpty || message.isEmpty || message == code ? (message.isEmpty ? code : message) : "\(code): \(message)"
        return text.isEmpty ? nil : text
    }

    public var description: String { message.isEmpty ? code : message }
    public var errorDescription: String? { description }

    /// The failure for the log: its code, its message and its details, so a daemon refusal such as
    /// `apps.unknown` names itself and what the daemon's catalog held (``description`` is the person's text).
    public var logDescription: String {
        var text = code.isEmpty ? message : "\(code): \(message)"
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        if let details, let data = try? encoder.encode(details), let json = String(data: data, encoding: .utf8) {
            text += " details=\(json)"
        }
        return text
    }

    /// ``logDescription`` of a ``CloudAppOpFailure``, else the error as it describes itself.
    public static func logText(_ error: any Error) -> String {
        (error as? CloudAppOpFailure)?.logDescription ?? String(describing: error)
    }
}

public extension JSONValue {
    /// The id of an app op's answer's `record` (`{"snapshot": {"id"}}`, `{"machine": {"id"}}`); nil when
    /// `record` is nil. An answer with no such id is `cmux.cloud.bad_response`.
    func recordID(_ record: String?, op: String) throws -> String? {
        guard let record else { return nil }
        guard let id = self[record]?["id"]?.stringValue, !id.isEmpty else {
            throw CloudAppOpFailure(code: "cmux.cloud.bad_response", message: "\(op) answered no \(record)")
        }
        return id
    }
}

/// One Cloud app op: `op`, JSON `args`, an idempotency key for a mutation
/// (nil for a read), and the wire origin.
public typealias CloudAppOp = @Sendable (_ op: String, _ args: JSONValue, _ key: String?, _ origin: AppsRunRequest.Origin) async throws -> JSONValue

/// A machine's pause or start on the app-server link (`cloud.machine.pause`, `cloud.machine.start`; cmux#32708), never
/// the classic `/api/vm`, which cannot reach a CloudDO machine. CloudDO answers once the provider call landed, so a
/// pause's answer means its active slot is free; a call longer than CloudDO's wait answers `mutation.indeterminate`,
/// asked again with the same key (it joins the call in flight) while Rust says so
/// (`cloud_power_retries`, cmux-cloud-start-core `machine_create`), at most `attempts` times in all.
public nonisolated struct CloudMachinePower {
    public nonisolated init() {}
    public static let indeterminate = "cmux.cloud.indeterminate"

    public static func run(_ op: String, machine: String, attempts: Int = 3,
                           origin: AppsRunRequest.Origin = .user, ops: CloudAppOp) async throws {
        let key = UUID().uuidString
        let tries = max(attempts, 1)
        for attempt in 1...tries {
            do {
                _ = try await ops(op, .object(["machine": .string(machine)]), key, origin)
                return
            } catch let failure as CloudAppOpFailure where CloudStartCore().powerRetries(code: failure.code, attempt: attempt, attempts: tries) {}
        }
    }
}
