import CmuxNextDaemon
@testable import CmuxNextMacScreen
import Testing

@MainActor
@Suite struct CaptureHelperResultTests {
    private func result(code: String = "helper_cleaned", started: Bool = true) -> JSONValue {
        .object(["ok": .bool(true), "code": .string(code),
                 "lease_bound": .bool(true), "worker_started": .bool(started),
                 "identity_removed": .number(0), "relays_removed": .number(0),
                 "verified_absent": .bool(true), "worker_quiescent": .bool(true),
                 "worker_pid_exited": .bool(true), "descendants_exited": .bool(true)])
    }

    @Test func everyDaemonProofMustBeTrue() {
        guard case .object(let valid) = result() else { Issue.record("fixture must be an object"); return }
        for field in ["ok", "lease_bound", "verified_absent", "worker_quiescent", "worker_pid_exited", "descendants_exited"] {
            var incomplete = valid
            incomplete[field] = .bool(false)
            #expect(CmuxHelperService.strictCaptureResult(.object(incomplete))["ok"] == .bool(false))
        }
    }

    @Test func runningHostOrWrongPhaseCannotProveCompletion() {
        for code in ["helper_exit_unverified", "helper_cleanup_unverified", "ok", "no_helper_started"] {
            #expect(CmuxHelperService.strictCaptureResult(result(code: code))["ok"] == .bool(false))
        }
        #expect(CmuxHelperService.strictCaptureResult(result(), phase: "prepare")["ok"] == .bool(false))
    }

    @Test func prepareAndUnusedCleanupPreservePristineDisposition() {
        let prepare = CmuxHelperService.strictCaptureResult(result(code: "no_helper_started", started: false), phase: "prepare")
        let cleanup = CmuxHelperService.strictCaptureResult(result(started: false))
        for proof in [prepare, cleanup] {
            #expect(proof["ok"] == .bool(true))
            #expect(proof["code"] == .string("no_helper_started"))
            #expect(proof["worker_pid_exited"] == .bool(true))
            #expect(proof["descendants_exited"] == .bool(true))
        }
    }

    @Test func completeDaemonCleanupMapsToPublicOK() {
        let proof = CmuxHelperService.strictCaptureResult(result())
        #expect(proof["ok"] == .bool(true))
        #expect(proof["code"] == .string("ok"))
    }

    @Test func missingOrMalformedProducerFieldsNeverProveCleanup() {
        guard case .object(let valid) = result() else { Issue.record("fixture must be an object"); return }
        for field in ["code", "ok", "lease_bound", "worker_started", "identity_removed", "relays_removed",
                      "verified_absent", "worker_quiescent", "worker_pid_exited", "descendants_exited"] {
            var missing = valid
            missing[field] = nil
            #expect(CmuxHelperService.strictCaptureResult(.object(missing))["ok"] == .bool(false))
        }
        let invalidCounts: [JSONValue] = [.number(-1), .number(0.5), .number(.infinity), .string("0"), .bool(false), .null]
        for field in ["identity_removed", "relays_removed"] {
            for invalid in invalidCounts {
                var malformed = valid
                malformed[field] = invalid
                #expect(CmuxHelperService.strictCaptureResult(.object(malformed))["ok"] == .bool(false))
            }
        }
        var malformed = valid
        malformed["worker_started"] = .string("false")
        #expect(CmuxHelperService.strictCaptureResult(.object(malformed))["ok"] == .bool(false))
    }

    @Test func pristineProofRejectsStartedWorkerOrRemovalCounts() {
        guard case .object(let valid) = result(code: "no_helper_started", started: false) else {
            Issue.record("fixture must be an object"); return
        }
        let changes: [(String, JSONValue)] = [("worker_started", .bool(true)),
                                              ("identity_removed", .number(1)), ("relays_removed", .number(1))]
        for (field, value) in changes {
            var nonPristine = valid
            nonPristine[field] = value
            #expect(CmuxHelperService.strictCaptureResult(.object(nonPristine), phase: "prepare")["ok"] == .bool(false))
        }
        var discrepancy = valid
        discrepancy["code"] = .string("helper_cleaned")
        discrepancy["identity_removed"] = .number(1)
        #expect(CmuxHelperService.strictCaptureResult(.object(discrepancy))["ok"] == .bool(false))
    }

    @Test func resumeRequiresExactBoundFreshProcessReceipt() {
        let valid: [String: JSONValue] = ["ok": .bool(true), "code": .string("helper_capture_resumed"), "lease_bound": .bool(true)]
        #expect(CmuxHelperService.strictCaptureResumeResult(.object(valid)) == .object(valid))
        for field in ["ok", "code", "lease_bound"] {
            var missing = valid
            missing[field] = nil
            #expect(CmuxHelperService.strictCaptureResumeResult(.object(missing))["ok"] == .bool(false))
        }
        for (field, value) in [("ok", JSONValue.bool(false)), ("lease_bound", .bool(false)),
                               ("code", .string("helper_cleaned")), ("unexpected", .bool(true))] {
            var malformed = valid
            malformed[field] = value
            #expect(CmuxHelperService.strictCaptureResumeResult(.object(malformed))["ok"] == .bool(false))
        }
    }
}
