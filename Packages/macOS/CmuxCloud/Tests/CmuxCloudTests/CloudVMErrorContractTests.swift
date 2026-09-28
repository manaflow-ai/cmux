import Foundation
import Testing
@testable import CmuxCloud
import CmuxSurfaceCatalogModel

struct CloudVMErrorContractTests {
    @Test("recreate-required responses explain the terminal machine state")
    func recreateRequiredResponseUsesTerminalCopy() {
        let body = #"{"error":"vm_requires_recreate","retryable":false}"#
        let text = formattedCloudVMHTTPError(status: 409, body: body)

        #expect(text.contains("This Cloud machine can no longer be attached"))
        #expect(!text.contains("Cloud service unavailable"))
    }

    @Test("automatic retries require the typed retryable contract")
    func retryableContractAndRetryAfterFloor() {
        let policy = CloudVMRetryPolicy(baseDelaySeconds: 2, maximumDelaySeconds: 8, maximumAttempts: 4)
        let retryable = CloudVMHTTPError(status: 502, body: #"{"error":"vm_cloud_service_unavailable","retryable":true,"retryAfterSeconds":7}"#)
        let decision = policy.decision(for: retryable, attempt: 1, elapsedSeconds: 0)
        #expect(decision == .retry(delay: .seconds(7)))

        let nonRetryable = CloudVMHTTPError(status: 502, body: #"{"error":"vm_cloud_service_unavailable","retryable":false}"#)
        #expect(policy.decision(for: nonRetryable, attempt: 1, elapsedSeconds: 0) == .stop)
    }

    @Test("terminal refusals stay sticky until the explicit reset")
    func terminalLedgerReset() {
        var ledger = CloudVMRetryLedger()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let terminal = CloudVMHTTPError(status: 409, body: #"{"error":"vm_requires_recreate","retryable":false}"#)
        ledger.recordFailure(machineID: "vm-1", error: terminal, now: start)
        #expect(ledger.admission(machineID: "vm-1", now: start.addingTimeInterval(86_400)) == .blocked(terminal))
        ledger.reset(machineID: "vm-1")
        #expect(ledger.admission(machineID: "vm-1", now: start) == .allowed)
    }

    @Test("pane failures expose recreate as the primary action")
    func paneFailureUsesRecreateState() {
        let failure = CloudPaneCreationFailure(
            machine: .cloud("vm-1"),
            error: VMClientError.typedHTTPStatus(CloudVMHTTPError(
                status: 409,
                body: #"{"error":"vm_requires_recreate","retryable":false}"#
            ))
        )
        #expect(failure.isRecreateRequired)
        #expect(failure.primaryActionTitle == "Recreate")
        #expect(failure.recoveryText.contains("recreated"))
    }

    @Test("formatted VM errors never echo upstream messages or trace ids")
    func formattedErrorIsPrivacySafe() {
        let text = formattedCloudVMHTTPError(
            status: 409,
            body: #"{"error":"vm_requires_recreate","message":"vendor-internal","action":"send secrets to vendor","traceId":"deadbeef","details":{"providerMessage":"private"}}"#
        )
        #expect(!text.contains("vendor-internal"))
        #expect(!text.contains("send secrets"))
        #expect(!text.contains("deadbeef"))
        #expect(!text.contains("private"))
    }

    @Test("attachment scheduler stops after a terminal refusal")
    @MainActor
    func attachmentSchedulerStops() {
        let scheduler = CloudTerminalAttachmentRetryScheduler()
        _ = scheduler.scheduleRetry {}
        scheduler.stop()
        #expect(scheduler.isStopped)
        #expect(!scheduler.isPending)
        #expect(scheduler.scheduleRetry {} == .zero)
    }
}
