@testable import CmuxNextAgentPane
import CmuxNextPalette
import Foundation
import Testing

/// The bar's pick history (`uses`) is in the part of a New Tab context that the pages share
/// (``AgentPaneNewTabShared``): the app makes that part's JSON text one time for the pages that have an equal
/// part. The history's scores decay with the clock. Read at each key's own time, each key of a held New Tab key
/// had other scores, so each page had its own text: one make of the large part for each key, for each person
/// who picked a row in the Commands palette before.
@MainActor @Suite
struct NewTabPickHistoryTextTests {
    static let pick = "action:newTab.page"

    @Test func theKeysOfOneMinuteHaveOneTextOfTheSharedPart() throws {
        let minute = Date(timeIntervalSinceReferenceDate: 780_000_000)
        var picks = FrecencyStore()
        picks.record(Self.pick, at: minute.addingTimeInterval(-3600))
        let palette = PaletteModel(frecency: picks)
        var clock = minute.addingTimeInterval(5)
        palette.now = { clock }

        let text = AgentPaneNewTabText()
        var scores: [Double] = []
        for _ in 0..<4 {
            let bar = AgentPaneOmnibar(uses: AgentPaneOmnibar.uses(of: palette))
            scores.append(try #require(bar.uses[Self.pick], "the pick is in the bar's history"))
            _ = text.text(of: AgentPaneNewTab(kind: .agent, omnibar: bar))
            clock = clock.addingTimeInterval(0.05)
        }
        #expect(Set(scores).count == 1, "4 keys, 50 ms apart in one minute: one score for the pick, not \(scores)")
        #expect(text.encodes == 1, "4 keys in one minute: one make of the shared part")

        // The decay stays: a key of the next minute reads a lower score.
        clock = minute.addingTimeInterval(65)
        let later = try #require(AgentPaneOmnibar.uses(of: palette)[Self.pick])
        #expect(later < scores[0])
    }
}
