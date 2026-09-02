import Foundation
import Testing
@testable import CmuxTuiManualIO

struct TuiManualIOPumpPolicyTests {
    @Test
    func relayExitClassificationUsesProtocolReason() {
        let policy = TuiManualIOPumpPolicy()
        #expect(policy.relayExit(status: 2, stderrText: #"{"exit":{"reason":"daemon-lost"}}"#) == .daemonLost)
        #expect(policy.relayExit(status: 2, stderrText: "usage error") == .failure)
        #expect(policy.relayExit(status: 0, stderrText: nil) == .failure)
        #expect(policy.relayExit(status: 0, stderrText: #"{"exit":{"reason":"unknown"}}"#) == .failure)
    }

    @Test
    func schedulerKeepsNewestResize() {
        let policy = TuiManualIOPumpPolicy()
        var scheduler = TuiManualIOResizeScheduler()
        scheduler.seed(delivered: TuiManualIOGrid(cols: 80, rows: 24))
        #expect(scheduler.sample(TuiManualIOGrid(cols: 100, rows: 30)) == TuiManualIOGrid(cols: 100, rows: 30))
        #expect(scheduler.sample(TuiManualIOGrid(cols: 101, rows: 30)) == nil)
        #expect(scheduler.acknowledged() == TuiManualIOGrid(cols: 101, rows: 30))
        #expect(policy.resizeLine(cols: 0, rows: 0) == Data(#"{"resize":{"cols":1,"rows":1}}"#.utf8 + [0x0A]))
    }
}
