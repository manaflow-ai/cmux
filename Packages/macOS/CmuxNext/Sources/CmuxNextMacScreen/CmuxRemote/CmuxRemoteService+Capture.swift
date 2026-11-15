public import CmuxNextDaemon
import Foundation

extension CmuxRemoteService {
    /// The daemon owns capture admission, app grants, child reaping and host
    /// exit. These calls never toggle the person's saved feature settings.
    /// Resume is only for the fresh signed-out app between prepare and the
    /// subsequent credentialed launch, with the exact original lease binding.
    public func capture(phase: String, leaseID: String, bundleID: String, privateRoot: String) async -> JSONValue {
        guard ["prepare", "resume", "cleanup"].contains(phase) else {
            return Self.captureFailure(code: "invalid_request")
        }
        let request: JSONValue = .object(["lease_id": .string(leaseID), "bundle_id": .string(bundleID),
                                          "private_root": .string(privateRoot)])
        do {
            let raw = try await call("capture." + phase, request, timeout: .seconds(70))
            return phase == "resume" ? Self.strictCaptureResumeResult(raw) : Self.strictCaptureResult(raw, phase: phase)
        } catch { return Self.captureFailure(code: "remote_unavailable") }
    }

    static func strictCaptureResumeResult(_ raw: JSONValue) -> JSONValue {
        guard case .object(let fields) = raw, fields.count == 3,
              fields["ok"]?.boolValue == true,
              fields["code"]?.stringValue == "remote_capture_resumed",
              fields["lease_bound"]?.boolValue == true else {
            return .object(["ok": .bool(false), "code": .string("remote_resume_unverified"), "lease_bound": .bool(false)])
        }
        return .object(["ok": .bool(true), "code": .string("remote_capture_resumed"), "lease_bound": .bool(true)])
    }

    static func strictCaptureResult(_ raw: JSONValue, phase: String = "cleanup") -> JSONValue {
        guard let code = raw["code"]?.stringValue,
              let producerOK = raw["ok"]?.boolValue,
              let workerStarted = raw["worker_started"]?.boolValue,
              let leaseBound = raw["lease_bound"]?.boolValue,
              let verifiedAbsent = raw["verified_absent"]?.boolValue,
              let workerQuiescent = raw["worker_quiescent"]?.boolValue,
              let workerExited = raw["worker_pid_exited"]?.boolValue,
              let descendantsExited = raw["descendants_exited"]?.boolValue,
              let identityRemoved = raw["identity_removed"]?.doubleValue,
              let identities = Int(exactly: identityRemoved), identities >= 0,
              let relaysRemoved = raw["relays_removed"]?.doubleValue,
              let relays = Int(exactly: relaysRemoved), relays >= 0 else {
            return captureFailure(code: "remote_invalid_result")
        }
        let terminal = producerOK && leaseBound && workerExited && descendantsExited && verifiedAbsent && workerQuiescent
        let pristine = !workerStarted && identities == 0 && relays == 0
        let prepared = phase == "prepare" && code == "no_remote_started" && pristine
        let cleaned = phase == "cleanup" && code == "remote_cleaned" && (workerStarted || pristine)
        let accepted = terminal && (prepared || cleaned)
        let publicCode = accepted ? (pristine ? "no_remote_started" : "ok") : code
        return .object(["ok": .bool(accepted), "code": .string(publicCode), "lease_bound": .bool(leaseBound),
                        "worker_started": .bool(workerStarted), "identity_removed": .number(identityRemoved),
                        "relays_removed": .number(relaysRemoved), "verified_absent": .bool(verifiedAbsent),
                        "worker_quiescent": .bool(workerQuiescent), "worker_pid_exited": .bool(workerExited),
                        "descendants_exited": .bool(descendantsExited)])
    }

    private static func captureFailure(code: String) -> JSONValue {
        .object(["ok": .bool(false), "code": .string(code), "lease_bound": .bool(false),
                 "worker_started": .bool(false), "identity_removed": .number(0), "relays_removed": .number(0),
                 "verified_absent": .bool(false), "worker_quiescent": .bool(false),
                 "worker_pid_exited": .bool(false), "descendants_exited": .bool(false)])
    }
}
