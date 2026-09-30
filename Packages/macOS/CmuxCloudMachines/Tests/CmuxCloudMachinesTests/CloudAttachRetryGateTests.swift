import Foundation
import Testing
@testable import CmuxCloudMachines

struct CloudAttachRetryGateTests {
    private let start = Date(timeIntervalSince1970: 1_790_000_000)

    private func body(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }

    // Production 2026-09: a legacy machine answered every attach with the same
    // permanent refusal, and the Mac retried about every 3.5 s for days.
    @Test func recreateRequiredHoldsTheMachineInsteadOfRetrying() throws {
        var gate = CloudAttachRetryGate()
        let failure = CloudAttachRetryGate.classify(status: 409, body: try body([
            "error": "vm_recreate_required", "retryable": false,
        ]))
        #expect(failure.kind == .recreateRequired)
        gate.recordFailure("vm-1", failure, now: start)
        // A poller asking every 3.5 s for the next half hour sends nothing.
        for tick in stride(from: 3.5, to: 30 * 60, by: 3.5) {
            #expect(gate.blockedUntil("vm-1", now: start.addingTimeInterval(tick)) != nil)
        }
        // A rare recheck lets an operator-repaired row recover.
        #expect(gate.blockedUntil("vm-1", now: start.addingTimeInterval(30 * 60)) == nil)
    }

    @Test func retryableFailuresBackOffExponentiallyToTheCap() {
        var gate = CloudAttachRetryGate(baseDelay: 2, maxDelay: 60)
        var now = start
        var delays: [TimeInterval] = []
        for _ in 0..<8 {
            let next = gate.recordFailure("vm-1", .init(kind: .retryable), now: now)
            delays.append(next.timeIntervalSince(now))
            now = next
        }
        #expect(delays == [2, 4, 8, 16, 32, 60, 60, 60])
    }

    @Test func retryAfterIsAFloorOnTheBackoff() throws {
        var gate = CloudAttachRetryGate(baseDelay: 2, maxDelay: 60)
        let failure = CloudAttachRetryGate.classify(status: 502, body: try body([
            "error": "vm_cloud_service_unavailable", "retryable": true, "retryAfterSeconds": 15,
        ]))
        #expect(failure == .init(kind: .retryable, retryAfterSeconds: 15))
        let next = gate.recordFailure("vm-1", failure, now: start)
        #expect(next.timeIntervalSince(start) == 15)
    }

    @Test func successClearsOnlyThatMachine() {
        var gate = CloudAttachRetryGate()
        gate.recordFailure("vm-1", .init(kind: .retryable), now: start)
        gate.recordFailure("vm-2", .init(kind: .recreateRequired), now: start)
        gate.recordSuccess("vm-1")
        #expect(gate.blockedUntil("vm-1", now: start) == nil)
        #expect(gate.blockedUntil("vm-2", now: start) != nil)
        // After success the backoff starts over from the base delay.
        let next = gate.recordFailure("vm-1", .init(kind: .retryable), now: start)
        #expect(next.timeIntervalSince(start) == gate.baseDelay)
    }

    @Test(arguments: [
        (401, #"{"error":"unauthorized"}"#),
        (502, #"{"error":"vm_cloud_service_unavailable","retryable":true}"#),
        (500, "<html>"),
        (409, #"{"error":"vm_attach_transport_unsupported","retryable":false}"#),
    ])
    func onlyTheRecreateCodeIsPermanent(status: Int, raw: String) {
        #expect(CloudAttachRetryGate.classify(status: status, body: Data(raw.utf8)).kind == .retryable)
        #expect(!CloudAttachRetryGate.isRecreateRequired(status: status, body: Data(raw.utf8)))
    }
}
