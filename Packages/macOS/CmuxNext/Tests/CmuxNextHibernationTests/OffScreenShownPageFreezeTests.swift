import CmuxNextHibernation
import CmuxNextSettings
import Testing

/// p07-memory-097, feature `offScreenWindowPageFreeze`: the page an off-screen window shows (the window's active tab)
/// freezes at once when its tab follows no visibility node, and never otherwise; hidden pages are unchanged.
@Suite struct OffScreenShownPageFreezeTests {
    let setting = BrowserHibernationSetting(mode: .minutes(60), freezeSeconds: 600)

    func shown(hiddenFor: Double = 1) -> HibernationPlanner.Candidate {
        var candidate = HibernationPlanner.Candidate(key: "shown", hiddenFor: hiddenFor)
        candidate.isActiveTab = true
        return candidate
    }

    @Test func theShownPageOfAnOffScreenWindowIsDueAtOnce() throws {
        let due = try #require(shown().freezeCandidate(freezesShownPages: true, followsNode: false, freezeSeconds: setting.freezeSeconds))
        #expect(HibernationPlanner.freezePlan(setting, candidates: [due]).due == ["shown"])
    }

    @Test func itStaysAwakeWithoutTheFeatureOrWhenItsNodeHidItOrWithNoFreeze() {
        #expect(shown().freezeCandidate(freezesShownPages: false, followsNode: false, freezeSeconds: 600) == nil)
        #expect(shown().freezeCandidate(freezesShownPages: true, followsNode: true, freezeSeconds: 600) == nil)
        #expect(shown().freezeCandidate(freezesShownPages: true, followsNode: false, freezeSeconds: nil) == nil)
    }

    @Test func aNeighborOrAnAgentsPageStaysAwakeAndAHiddenPageKeepsItsClock() {
        var neighbor = HibernationPlanner.Candidate(key: "n", hiddenFor: 1)
        neighbor.isNeighbor = true
        var driven = shown()
        driven.isAgentDriving = true
        #expect(neighbor.freezeCandidate(freezesShownPages: true, followsNode: false, freezeSeconds: 600) == nil)
        #expect(driven.freezeCandidate(freezesShownPages: true, followsNode: false, freezeSeconds: 600) == nil)
        let hidden = HibernationPlanner.Candidate(key: "h", hiddenFor: 1)
        #expect(hidden.freezeCandidate(freezesShownPages: true, followsNode: false, freezeSeconds: 600) == hidden)
    }
}
