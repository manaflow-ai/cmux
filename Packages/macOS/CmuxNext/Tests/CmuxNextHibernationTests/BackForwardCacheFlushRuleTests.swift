import CmuxNextCompat
import CmuxNextHibernation
import Testing

/// ``BackForwardCacheFlushRule`` (p07-memory-101): with the feature, a freeze flushes, the hidden pages that are not
/// frozen flush once when the pressure leaves normal, and a hide above normal flushes; nothing flushes on any other
/// change or with the feature off.
@Suite struct BackForwardCacheFlushRuleTests {
    let hidden = ["a", "b", "c"]

    @Test func theRiseFromNormalFlushesEveryHiddenPageButTheFrozenOnes() {
        let rule = BackForwardCacheFlushRule(isEnabled: true)
        #expect(rule.flushes(from: .normal, to: .warning, hidden: hidden, frozen: ["b"]) == ["a", "c"])
        #expect(rule.flushes(from: .normal, to: .critical, hidden: hidden, frozen: []) == hidden)
        #expect(rule.flushesAtFreeze)
    }

    @Test func aHideAboveNormalFlushes() {
        let rule = BackForwardCacheFlushRule(isEnabled: true)
        #expect(rule.flushesAtHide(pressure: .warning))
        #expect(rule.flushesAtHide(pressure: .critical))
        #expect(!rule.flushesAtHide(pressure: .normal))
    }

    @Test func noOtherChangeFlushes() {
        let rule = BackForwardCacheFlushRule(isEnabled: true)
        for (old, new) in [(MemoryPressureLevel.warning, MemoryPressureLevel.critical), (.critical, .warning), (.warning, .normal), (.critical, .normal)] {
            #expect(rule.flushes(from: old, to: new, hidden: hidden, frozen: []).isEmpty, "\(old) to \(new) flushed")
        }
    }

    @Test func offNothingFlushes() {
        let rule = BackForwardCacheFlushRule()
        #expect(rule.flushes(from: .normal, to: .warning, hidden: hidden, frozen: []).isEmpty)
        #expect(!rule.flushesAtFreeze)
        #expect(!rule.flushesAtHide(pressure: .critical))
    }
}
