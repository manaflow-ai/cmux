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

    /// The minute step holds the clock's decay only. A pick is a change of the history: the next key has the
    /// pick's new score and another text, also when the pick and the 2 keys are in one minute.
    @Test func aPickInsideTheMinuteGivesTheNextKeyAnotherText() throws {
        let minute = Date(timeIntervalSinceReferenceDate: 780_000_000)
        var picks = FrecencyStore()
        picks.record(Self.pick, at: minute.addingTimeInterval(-3600))
        let palette = PaletteModel(frecency: picks)
        var clock = minute.addingTimeInterval(5)
        palette.now = { clock }

        let text = AgentPaneNewTabText()
        func key() throws -> (uses: [String: Double], generation: Int) {
            let bar = AgentPaneOmnibar(uses: AgentPaneOmnibar.uses(of: palette))
            let made = try #require(text.text(of: AgentPaneNewTab(kind: .agent, omnibar: bar)), "the shared part has a text")
            return (bar.uses, made.generation)
        }
        let before = try key()
        clock = clock.addingTimeInterval(1)
        palette.recordUse(Self.pick)
        palette.recordUse("workspace:picked-now")
        clock = clock.addingTimeInterval(1)
        let after = try key()

        let was = try #require(before.uses[Self.pick]), now = try #require(after.uses[Self.pick])
        #expect(now > was, "a second pick of the row, 1 s before the key and in the key's minute: its score rises (\(was) to \(now))")
        #expect(after.uses["workspace:picked-now"] != nil, "a first pick of a row, 1 s before the key: the row is in the bar's history")
        #expect(after.generation != before.generation, "the key after a pick has another text of the shared part")
        #expect(text.encodes == 2, "one make for the key before the pick, one for the key after it")
    }
}
