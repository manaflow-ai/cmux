@testable import CmuxCloud
import Foundation
import Testing

/// The server answers inside the budget a request states
/// (web/services/vms/routeDeadline.ts). The stated budget must be the
/// earliest deadline any layer will actually wait for, never the longer
/// URLRequest timeout alone. Every budget here runs on a frozen clock, so
/// deadlines compare exactly.
@Suite
struct CloudRequestBudgetTests {
    private let budget = CloudRequestBudget(clock: { 100 })

    @Test("an unset URLRequest timeout is the 60 s default")
    func defaultTimeout() {
        #expect(budget.effectiveTimeout(urlTimeout: nil) == 60)
    }

    @Test("an outer deadline earlier than the URLRequest timeout wins")
    func outerDeadlineWins() async {
        // The socket worker or CLI gives up in 20 s; the request alone would wait 16 min.
        let timeout = await budget.withBudget(seconds: 20) { budget.effectiveTimeout(urlTimeout: 960) }
        #expect(timeout == 20)
    }

    @Test("a later outer deadline does not stretch the URLRequest timeout")
    func laterDeadlineDoesNotStretch() async {
        let timeout = await budget.withBudget(seconds: 900) { budget.effectiveTimeout(urlTimeout: 30) }
        #expect(timeout == 30)
    }

    @Test("a spent budget still yields the minimum timeout")
    func spentBudget() async {
        let timeout = await budget.withBudget(seconds: 0) { budget.effectiveTimeout(urlTimeout: 60) }
        #expect(timeout == CloudRequestBudget.minimumTimeout)
    }

    @Test("the header carries whole milliseconds")
    func headerValue() {
        #expect(budget.headerValue(seconds: 20.0009) == "20000")
        #expect(CloudRequestBudget.headerField == "x-cmux-client-timeout-ms")
    }

    @Test("a nested budget never extends an enclosing earlier one")
    func nestedBudgetKeepsEarliest() async {
        let inner = await budget.withBudget(seconds: 20) {
            await budget.withBudget(seconds: 960) { budget.deadline }
        }
        #expect(inner == 120)
        #expect(budget.deadline == nil)
    }

    @Test("a nested earlier budget narrows the enclosing one")
    func nestedEarlierBudgetNarrows() async {
        let inner = await budget.withBudget(seconds: 60) {
            await budget.withBudget(seconds: 5) { budget.deadline }
        }
        #expect(inner == 105)
    }

    @Test("a nil budget keeps the enclosing deadline")
    func nilBudgetKeepsEnclosing() async {
        let inner = await budget.withBudget(seconds: 30) {
            await budget.withBudget(seconds: nil) { budget.deadline }
        }
        #expect(inner == 130)
    }

    @Test("a replaced budget ignores the enclosing shorter deadline")
    func replacedBudgetIgnoresEnclosing() async {
        let inner = await budget.withBudget(seconds: 5) {
            await budget.withReplacedBudget(seconds: 30) { budget.deadline }
        }
        #expect(inner == 130)
    }

    @Test("the synchronous form binds the same deadline")
    func synchronousBudget() {
        let bound = budget.withBudgetSync(seconds: 15) { budget.deadline }
        #expect(bound == 115)
    }

    @Test("the remaining time is the deadline less now")
    func remainingSeconds() async {
        #expect(budget.remainingSeconds() == nil)
        let remaining = await budget.withBudget(seconds: 42) { budget.remainingSeconds() }
        #expect(remaining == 42)
    }
}

@Suite
struct CloudRequestBudgetSocketParamTests {
    private let budget = CloudRequestBudget(clock: { 0 })

    @Test("the socket budget param is stripped and read in seconds")
    func stripsAndReads() {
        let split = budget.socketClientBudget(from: ["id": "vm-1", "cloud_client_timeout_ms": 20_000])
        #expect(split.seconds == 20)
        #expect(split.params["cloud_client_timeout_ms"] == nil)
        #expect(split.params["id"] as? String == "vm-1")
    }

    @Test("an invalid socket budget param is stripped and ignored")
    func invalidIgnored() {
        for raw: Any in ["soon", -5, 0] {
            let split = budget.socketClientBudget(from: ["cloud_client_timeout_ms": raw])
            #expect(split.seconds == nil)
            #expect(split.params.isEmpty)
        }
    }

    @Test("params without a budget pass through")
    func passThrough() {
        let split = budget.socketClientBudget(from: ["id": "vm-1"])
        #expect(split.seconds == nil)
        #expect(split.params["id"] as? String == "vm-1")
    }
}
