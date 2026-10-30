import CmuxNextDesign
import Testing

/// The first file-picker click of a launch is not cold: the made-ahead panel's warm-up starts when the app's launch
/// settles, not only when a view that offers the picker reaches a window (Lead decision 2026-10-23).
@MainActor
struct MadeAheadOpenPanelLaunchWarmUpTests {
    @Test func theWarmUpStartsWhenTheScheduleRunsIt() {
        let panel = MadeAheadOpenPanel()
        var pending: [@MainActor () -> Void] = []
        panel.warmWhenIdle(after: { pending.append($0) })
        #expect(!panel.isWarming, "the warm-up started before the launch settled (it would compete with the first frame)")
        #expect(pending.count == 1)
        pending.forEach { $0() }
        #expect(panel.isWarming, "the launch settled and no warm-up is pending: the first click makes its panel cold")
    }
}
