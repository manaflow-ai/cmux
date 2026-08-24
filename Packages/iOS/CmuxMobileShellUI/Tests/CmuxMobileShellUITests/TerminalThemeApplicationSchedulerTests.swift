#if canImport(UIKit)
import Testing
@testable import CmuxMobileShellUI

@Suite("Terminal theme application scheduler")
@MainActor
struct TerminalThemeApplicationSchedulerTests {
    @Test func coalescesQueuedApplicationsToLatestGeneration() async {
        let scheduler = TerminalThemeApplicationScheduler(minimumApplicationInterval: .zero)
        var applied: [UInt64] = []

        for generation in 1...3 {
            scheduler.schedule(generation: UInt64(generation)) {
                applied.append(UInt64(generation))
            }
        }
        for _ in 0..<4 { await Task.yield() }

        #expect(applied == [3])
        #expect(scheduler.lastAppliedGeneration == 3)
        #expect(scheduler.pendingGeneration == nil)
    }

    @Test func retainsOnlyNewestApplicationWhileRateLimited() async {
        let scheduler = TerminalThemeApplicationScheduler(minimumApplicationInterval: .seconds(60))
        scheduler.seed(generation: 1)
        var applied: [UInt64] = []

        scheduler.schedule(generation: 2) { applied.append(2) }
        scheduler.schedule(generation: 3) { applied.append(3) }
        for _ in 0..<4 { await Task.yield() }

        #expect(applied.isEmpty)
        #expect(scheduler.pendingGeneration == 3)
        scheduler.cancel()
    }
}
#endif
