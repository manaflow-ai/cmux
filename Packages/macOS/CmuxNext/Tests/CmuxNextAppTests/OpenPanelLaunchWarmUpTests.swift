@testable import CmuxNextApp
import CmuxNextDesign
import Testing

/// The first file-picker click of a launch is not cold: the made-ahead panel's warm-up starts once the launch settles,
/// not only when a view that offers the picker reaches a window (Lead decision 2026-10-23).
@MainActor
struct OpenPanelLaunchWarmUpTests {
    @Test func theWarmUpStartsWhenTheLaunchSettles() {
        let panel = MadeAheadOpenPanel()
        let settle = LaunchSettle()
        OpenPanelLaunchWarmUp(openPanel: panel).schedule(on: settle)
        #expect(!panel.isWarming, "the warm-up started before the launch settled (it would compete with the first frame)")
        settle.settle()
        #expect(panel.isWarming, "the launch settled and no warm-up is pending: the first click makes its panel cold")
    }
}
