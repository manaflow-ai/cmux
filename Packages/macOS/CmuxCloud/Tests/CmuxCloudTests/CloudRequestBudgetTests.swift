@testable import CmuxCloud
import Foundation
import Testing

/// The server answers inside the budget a request states
/// (web/services/vms/routeDeadline.ts). The stated budget must be the
/// earliest deadline any layer will actually wait for, never the longer
/// URLRequest timeout alone.
@Suite
struct CloudRequestBudgetTests {
    @Test("an unset URLRequest timeout is the 60 s default")
    func defaultTimeout() {
        #expect(CloudRequestBudget.effectiveTimeout(urlTimeout: nil, deadline: nil, now: 100) == 60)
    }

    @Test("an outer deadline earlier than the URLRequest timeout wins")
    func outerDeadlineWins() {
        // The socket worker or CLI gives up in 20 s; the request alone would wait 16 min.
        #expect(CloudRequestBudget.effectiveTimeout(urlTimeout: 960, deadline: 120, now: 100) == 20)
    }

    @Test("a later outer deadline does not stretch the URLRequest timeout")
    func laterDeadlineDoesNotStretch() {
        #expect(CloudRequestBudget.effectiveTimeout(urlTimeout: 30, deadline: 1_000, now: 100) == 30)
    }

    @Test("a spent budget still yields the minimum timeout")
    func spentBudget() {
        #expect(CloudRequestBudget.effectiveTimeout(urlTimeout: 60, deadline: 90, now: 100) == CloudRequestBudget.minimumTimeout)
    }

    @Test("the header carries whole milliseconds")
    func headerValue() {
        #expect(CloudRequestBudget.headerValue(seconds: 20.0009) == "20000")
        #expect(CloudRequestBudget.headerField == "x-cmux-client-timeout-ms")
    }

    @Test("a nested budget never extends an enclosing earlier one")
    func nestedBudgetKeepsEarliest() async {
        let start = CloudRequestBudget.now()
        let observed = await CloudRequestBudget.withBudget(seconds: 20) {
            await CloudRequestBudget.withBudget(seconds: 960) { CloudRequestBudget.deadline }
        }
        let deadline = try? #require(observed)
        #expect((deadline ?? .infinity) - start <= 21)
        #expect(CloudRequestBudget.deadline == nil)
    }

    @Test("a nil budget keeps the enclosing deadline")
    func nilBudgetKeepsEnclosing() async {
        let inner = await CloudRequestBudget.withBudget(seconds: 30) {
            await CloudRequestBudget.withBudget(seconds: nil) { CloudRequestBudget.deadline }
        }
        #expect(inner != nil)
    }
}
