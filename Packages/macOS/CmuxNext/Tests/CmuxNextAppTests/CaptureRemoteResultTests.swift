import CmuxNextDaemon
@testable import CmuxNextMacScreen
import Testing

@MainActor
@Suite struct CaptureRemoteResultTests {
    private func result(code: String = "remote_exit_unverified", lease: Bool = true,
                        absent: Bool = true, quiescent: Bool = true) -> JSONValue {
        .object(["ok": .bool(code == "no_remote_started"), "code": .string(code),
                 "lease_bound": .bool(lease), "worker_started": .bool(false),
                 "identity_removed": .number(0), "relays_removed": .number(0),
                 "verified_absent": .bool(absent), "worker_quiescent": .bool(quiescent),
                 "worker_pid_exited": .bool(false), "descendants_exited": .bool(false)])
    }

    @Test func producerCannotProveItsOwnExit() {
        for code in ["no_remote_started", "remote_exit_unverified", "ok"] {
            #expect(CmuxRemoteService.strictCaptureResult(result(code: code))["ok"] == .bool(false))
        }
    }

    @Test func observedExitStillRequiresEveryProducerProof() {
        for raw in [result(lease: false), result(absent: false), result(quiescent: false),
                    result(code: "remote_cleanup_unverified"), result(code: "ok")] {
            #expect(CmuxRemoteService.strictCaptureResult(raw, exited: true)["ok"] == .bool(false))
        }
    }

    @Test func preparePreservesItsCodeAfterObservedExit() {
        let proof = CmuxRemoteService.strictCaptureResult(result(code: "no_remote_started"), exited: true)
        #expect(proof["ok"] == .bool(true))
        #expect(proof["code"] == .string("no_remote_started"))
        #expect(proof["worker_pid_exited"] == .bool(true))
        #expect(proof["descendants_exited"] == .bool(true))
    }

    @Test func cleanupPromotesOnlyAfterObservedExit() {
        let proof = CmuxRemoteService.strictCaptureResult(result(), exited: true)
        #expect(proof["ok"] == .bool(true))
        #expect(proof["code"] == .string("ok"))
    }

    @Test func missingOrMalformedProducerFieldsNeverProveCleanup() {
        guard case .object(let valid) = result() else { Issue.record("fixture must be an object"); return }
        for field in ["code", "ok", "lease_bound", "worker_started", "identity_removed", "relays_removed",
                      "verified_absent", "worker_quiescent", "worker_pid_exited", "descendants_exited"] {
            var missing = valid
            missing[field] = nil
            #expect(CmuxRemoteService.strictCaptureResult(.object(missing), exited: true)["ok"] == .bool(false))
        }
        let invalidCounts: [JSONValue] = [.number(-1), .number(0.5), .number(.infinity), .string("0"), .bool(false), .null]
        for field in ["identity_removed", "relays_removed"] {
            for invalid in invalidCounts {
                var malformed = valid
                malformed[field] = invalid
                #expect(CmuxRemoteService.strictCaptureResult(.object(malformed), exited: true)["ok"] == .bool(false))
            }
        }
        var malformed = valid
        malformed["worker_started"] = .string("false")
        #expect(CmuxRemoteService.strictCaptureResult(.object(malformed), exited: true)["ok"] == .bool(false))
    }

    @Test func pristinePrepareRejectsStartedWorkerOrRemovalCounts() {
        guard case .object(let valid) = result(code: "no_remote_started") else {
            Issue.record("fixture must be an object"); return
        }
        let changes: [(String, JSONValue)] = [("worker_started", .bool(true)),
                                              ("identity_removed", .number(1)), ("relays_removed", .number(1))]
        for (field, value) in changes {
            var nonPristine = valid
            nonPristine[field] = value
            #expect(CmuxRemoteService.strictCaptureResult(.object(nonPristine), exited: true)["ok"] == .bool(false))
        }
    }
}
