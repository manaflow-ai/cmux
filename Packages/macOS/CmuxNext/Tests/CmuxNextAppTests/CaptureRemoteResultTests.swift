import CmuxNextDaemon
@testable import CmuxNextMacScreen
import Testing

@MainActor
@Suite struct CaptureRemoteResultTests {
    private func result(code: String = "remote_cleaned", started: Bool = true) -> JSONValue {
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
            #expect(CmuxRemoteService.captureResult(phase: "cleanup", raw: .object(incomplete))["ok"] == .bool(false))
        }
    }

    @Test func runningHostOrWrongPhaseCannotProveCompletion() {
        for code in ["remote_exit_unverified", "remote_cleanup_unverified", "ok", "no_remote_started"] {
            #expect(CmuxRemoteService.captureResult(phase: "cleanup", raw: result(code: code))["ok"] == .bool(false))
        }
        #expect(CmuxRemoteService.captureResult(phase: "prepare", raw: result())["ok"] == .bool(false))
    }

    @Test func prepareAndUnusedCleanupPreservePristineDisposition() {
        let prepare = CmuxRemoteService.captureResult(phase: "prepare", raw: result(code: "no_remote_started", started: false))
        let cleanup = CmuxRemoteService.captureResult(phase: "cleanup", raw: result(started: false))
        for proof in [prepare, cleanup] {
            #expect(proof["ok"] == .bool(true))
            #expect(proof["code"] == .string("no_remote_started"))
            #expect(proof["worker_pid_exited"] == .bool(true))
            #expect(proof["descendants_exited"] == .bool(true))
        }
    }

    @Test func completeDaemonCleanupMapsToPublicOK() {
        let proof = CmuxRemoteService.captureResult(phase: "cleanup", raw: result())
        #expect(proof["ok"] == .bool(true))
        #expect(proof["code"] == .string("ok"))
    }

    @Test func missingOrMalformedProducerFieldsNeverProveCleanup() {
        guard case .object(let valid) = result() else { Issue.record("fixture must be an object"); return }
        for field in ["code", "ok", "lease_bound", "worker_started", "identity_removed", "relays_removed",
                      "verified_absent", "worker_quiescent", "worker_pid_exited", "descendants_exited"] {
            var missing = valid
            missing[field] = nil
            #expect(CmuxRemoteService.captureResult(phase: "cleanup", raw: .object(missing))["ok"] == .bool(false))
        }
        let invalidCounts: [JSONValue] = [.number(-1), .number(0.5), .number(.infinity), .string("0"), .bool(false), .null]
        for field in ["identity_removed", "relays_removed"] {
            for invalid in invalidCounts {
                var malformed = valid
                malformed[field] = invalid
                #expect(CmuxRemoteService.captureResult(phase: "cleanup", raw: .object(malformed))["ok"] == .bool(false))
            }
        }
        var malformed = valid
        malformed["worker_started"] = .string("false")
        #expect(CmuxRemoteService.captureResult(phase: "cleanup", raw: .object(malformed))["ok"] == .bool(false))
    }

    @Test func pristineProofRejectsStartedWorkerOrRemovalCounts() {
        guard case .object(let valid) = result(code: "no_remote_started", started: false) else {
            Issue.record("fixture must be an object"); return
        }
        let changes: [(String, JSONValue)] = [("worker_started", .bool(true)),
                                              ("identity_removed", .number(1)), ("relays_removed", .number(1))]
        for (field, value) in changes {
            var nonPristine = valid
            nonPristine[field] = value
            #expect(CmuxRemoteService.captureResult(phase: "prepare", raw: .object(nonPristine))["ok"] == .bool(false))
        }
        var discrepancy = valid
        discrepancy["code"] = .string("remote_cleaned")
        discrepancy["identity_removed"] = .number(1)
        #expect(CmuxRemoteService.captureResult(phase: "cleanup", raw: .object(discrepancy))["ok"] == .bool(false))
    }

    @Test func resumeRequiresExactBoundFreshProcessReceipt() {
        let valid: [String: JSONValue] = ["ok": .bool(true), "code": .string("remote_capture_resumed"), "lease_bound": .bool(true)]
        #expect(CmuxRemoteService.captureResult(phase: "resume", raw: .object(valid)) == .object(valid))
        for field in ["ok", "code", "lease_bound"] {
            var missing = valid
            missing[field] = nil
            #expect(CmuxRemoteService.captureResult(phase: "resume", raw: .object(missing))["ok"] == .bool(false))
        }
        for (field, value) in [("ok", JSONValue.bool(false)), ("lease_bound", .bool(false)),
                               ("code", .string("remote_cleaned")), ("unexpected", .bool(true))] {
            var malformed = valid
            malformed[field] = value
            #expect(CmuxRemoteService.captureResult(phase: "resume", raw: .object(malformed))["ok"] == .bool(false))
        }
    }
}
