@testable import CmuxNextApp
@testable import CmuxNextBrowser
import CmuxNextMemory
import Testing

/// The Chromium engine's shared-renderer memory caps come from the app's memory budget, so
/// Chromium starts with `cmux-shared-renderer-memory-limit` at Chrome's 2 GiB and the subframe limit at 512 MiB
/// on every Mac.
struct ChromiumSharedRendererMemoryCapsTests {
    @Test(arguments: [UInt64(8), 16, 64])
    func theEnginesCapsAreTheBudgets(gigabytes: UInt64) {
        let budget = SubsystemBudget.forMemory(physicalBytes: gigabytes << 30, gpuResidentAvailable: false)
        let caps = AppServices.sharedRendererMemoryCaps(budget)
        #expect(caps == CEFSharedRendererMemoryCaps(mainFrameBytes: budget.sharedRendererMemoryCapBytes,
                                                    subframeBytes: budget.sharedRendererSubframeMemoryCapBytes))
        #expect(caps.arguments == ["cmux-shared-renderer-memory-limit=2147483648",
                                   "cmux-shared-renderer-subframe-memory-limit=536870912"])
    }
}
