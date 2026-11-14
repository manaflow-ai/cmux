import CmuxNextDaemon
@testable import CmuxNextMacScreen
import Testing

@MainActor
@Suite struct CaptureRemoteResultTests {
    private func result(code: String = "remote_exit_unverified", lease: Bool = true,
                        absent: Bool = true, quiescent: Bool = true) -> JSONValue {
        .object(["ok": .bool(code == "no_remote_started"), "code": .string(code),
                 "lease_bound": .bool(lease), "worker_started": .bool(false),
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
}
