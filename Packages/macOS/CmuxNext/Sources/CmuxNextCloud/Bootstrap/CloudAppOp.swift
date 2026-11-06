public import CmuxNextDaemon
import Foundation

/// Cloud ops through the Cloud app server (`cmux/cloud`, contract 2.1):
/// `apps-run` on the local daemon; the server checks the args and origin,
/// keeps the machine projection, and reaches the cmux-next API Worker
/// through the host credential relay (install token, `CloudCredentialProvider`).
/// Never `/api/vm`.
public nonisolated struct CloudAppOpFailure: Error, Equatable, Sendable, CustomStringConvertible {
    /// The server's code (`cmux.cloud.<reason>`).
    public var code: String
    public var message: String
    public var details: JSONValue?

    public static let approvalPending = "cmux.cloud.approval_pending"
    /// The op needs a paid plan (`cloud.plan.required`).
    public static let planRequired = "cmux.cloud.plan_required"

    public init(code: String, message: String, details: JSONValue? = nil) {
        self.code = code
        self.message = message
        self.details = details
    }

    /// The approval request id (`apr_…`) of an approval code.
    public var approvalRequest: String? { details?["request"]?.stringValue }

    public var description: String { message.isEmpty ? code : message }
}

/// One Cloud app op: `op`, JSON `args`, an idempotency key for a mutation
/// (nil for a read), and the wire origin.
public typealias CloudAppOp = @Sendable (_ op: String, _ args: JSONValue, _ key: String?, _ origin: AppsRunRequest.Origin) async throws -> JSONValue

/// A machine's pause or start on the app-server link (`cloud.machine.pause`, `cloud.machine.start`; cmux#32708), never
/// the classic `/api/vm`, which cannot reach a CloudDO machine. CloudDO answers once the provider call landed, so a
/// pause's answer means its active slot is free; a call longer than CloudDO's wait answers `mutation.indeterminate`,
/// asked again with the same key (it joins the call in flight), at most `attempts` times in all.
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
            } catch let failure as CloudAppOpFailure where failure.code == indeterminate && attempt < tries {}
        }
    }
}
