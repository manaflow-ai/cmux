public import CmuxNextDaemon
import Foundation

extension CmuxRemoteService {
    /// The daemon owns capture admission, app grants, child reaping and host
    /// exit. These calls never toggle the person's saved feature settings.
    /// Resume is only for the fresh signed-out app between prepare and the
    /// subsequent credentialed launch, with the exact original lease binding.
    /// Rust keeps only a verified, terminal answer (service.capture).
    public func capture(phase: String, leaseID: String, bundleID: String, privateRoot: String) async -> JSONValue {
        guard ["prepare", "resume", "cleanup"].contains(phase) else { return Self.captureResult(phase: phase, failure: "invalid_request") }
        let request: JSONValue = .object(["lease_id": .string(leaseID), "bundle_id": .string(bundleID),
                                          "private_root": .string(privateRoot)])
        guard let raw = try? await call("capture." + phase, request, timeout: .seconds(70)) else {
            return Self.captureResult(phase: phase, failure: "remote_unavailable")
        }
        return Self.captureResult(phase: phase, raw: raw)
    }

    /// A phase's public answer from the daemon's raw one, or a failure with `failure`'s code.
    static func captureResult(phase: String, raw: JSONValue = .null, failure: String? = nil) -> JSONValue {
        var args: [String: JSONValue] = ["phase": .string(phase), "raw": raw]
        if let failure { args["failure"] = .string(failure) }
        let answer = RdUI.call("service.capture", encoding: args)
        // main-actor-ok: one capture answer's small dictionary, re-typed
        guard let answer, let data = try? JSONSerialization.data(withJSONObject: answer),
              // main-actor-ok: the same small answer, re-typed
              let value = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            return .object(["ok": .bool(false), "code": .string("remote_invalid_result"), "lease_bound": .bool(false)])
        }
        return value
    }
}
