public import CmuxNextActions
public import CmuxNextHomeEngine
import Foundation

// `cmux cloud chief-computer --chief <id> --op <op> [--args <json>]`: a Chief of this Mac drives its own computer
// (Set Up Computer in its profile; backend chief-brain/local-computer-routes.ts `POST …/computer/act`). Its
// `cloud_computer` tool runs it for the `chief:<id>` computer its engine.json names.
//
// Trust: the Worker holds every rule (the owner's session only, the lease: refused with
// computer.human_has_control while the person holds it). This app adds one: a change from another client
// (`remote`: a phone, another Mac) is refused, as for `cloud.computerControl`.
extension ChiefComputerControlClient {
    /// The ops the route takes for the Chief's own verbs (backend ACT_OPS).
    static let actOps: Set<String> = ["screenshot", "windows", "click", "move", "drag", "scroll", "type", "key", "open", "control", "request_human", "hand_back", "start"]

    /// One `cloud.chiefComputer` run: the route's value as the result's fields, or its refusal with its code.
    @MainActor
    public func actEffect(_ invocation: ActionInvocation) -> ActionEffect {
        if (ActionRunScope.current?.origin ?? invocation.origin) == .remote {
            return .refused(String(localized: "cloud.chiefComputer.remote", defaultValue: "Only this Mac drives its Chief's computer.", table: "HostedChief", bundle: .module))
        }
        let chief = invocation["chief"]?.stringValue.map { $0.hasPrefix("chief:") ? String($0.dropFirst("chief:".count)) : $0 } ?? ""
        let op = invocation["op"]?.stringValue ?? ""
        guard let key = HomeChiefComputerRoute.localKey(chief), Self.actOps.contains(op) else {
            return .refused(String(localized: "cloud.chiefComputer.invalid", defaultValue: "Name the Chief's computer (chief:<id>) and one of its ops.", table: "HostedChief", bundle: .module))
        }
        let args = invocation["args"]?.stringValue.flatMap { $0.data(using: .utf8) }.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        let body = args.merging(["op": op]) { _, new in new }
        return .applied(result: {
            do {
                let value = try await act(agent: key, body)
                return .success(value.compactMapValues(Self.resultValue))
            } catch let failure as Failure {
                return .failure(ActionWorkFailure(code: failure.code ?? "computer.unreachable", reason: failure.errorDescription ?? ""))
            } catch {
                return .failure(ActionWorkFailure(String(describing: error)))
            }
        })
    }

    /// A JSON value as a result field; nil for what JSON does not carry.
    static func resultValue(_ json: Any) -> ActionResultValue? {
        switch json {
        case let value as String: .string(value)
        case let value as NSNumber where CFGetTypeID(value) == CFBooleanGetTypeID(): .bool(value.boolValue)
        case let value as NSNumber: value.doubleValue == value.doubleValue.rounded() ? .int(value.intValue) : .double(value.doubleValue)
        case let value as [Any]: .array(value.compactMap(resultValue))
        case let value as [String: Any]: .object(value.compactMapValues(resultValue))
        case is NSNull: .null
        default: nil
        }
    }
}
