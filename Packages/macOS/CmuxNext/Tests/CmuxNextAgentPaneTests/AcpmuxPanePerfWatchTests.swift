import Foundation
import Testing
@testable import CmuxNextAgentPane

/// The chat Inspector's Perf tab and page reporter reach acpmux's perf watch (`_acpmux/perf`), with
/// only the params they send.
@Suite struct AcpmuxPanePerfWatchTests {
    @Test func perfWatchTakesItsOwnParamsOnly() {
        #expect(AcpmuxPaneMethods.requests.contains("_acpmux/perf"))
        let sent: [[String: Any]] = [
            ["op": "status"], ["op": "on"], ["op": "off"], ["op": "snapshot"],
            ["op": "read", "after": 12, "limit": 500, "waitMs": 20_000],
            ["op": "report", "page": "chat", "windowMs": 1_000, "spans": [], "renders": ["Row": 2],
             "frames": [60], "layoutShifts": [], "bytes": []],
            // frameTally.ts: refused, every tally was dropped and counted as a chat refusal.
            ["op": "tally", "bucketMs": 0.1, "gaps": [[83, 10]]],
            ["op": "frames"],
        ]
        for params in sent {
            #expect(!AcpmuxPaneMethods.breaksParamsRule(["method": "_acpmux/perf", "params": params], modeFields: nil))
        }
        for params in [["op": "on", "file": "/tmp/x"], ["command": "pwd"], ["op": "read", "sessionId": "s"]] {
            #expect(AcpmuxPaneMethods.breaksParamsRule(["method": "_acpmux/perf", "params": params], modeFields: nil))
        }
    }
}
