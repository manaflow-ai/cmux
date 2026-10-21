import Testing
@testable import CmuxMobileTerminal

/// verify/perf-latency.md: previously shown terminal tabs stay warm (live
/// surface, attached session) up to a bound; older ones are cooled.
@Suite struct TerminalWarmSetTests {
    @Test func keepsTheMostRecentlyShownUpToTheLimit() {
        var warm = TerminalWarmSet<String>(limit: 3)
        #expect(warm.touch("a") == [])
        #expect(warm.touch("b") == [])
        #expect(warm.touch("c") == [])
        #expect(warm.touch("d") == ["a"])
        #expect(warm.order == ["b", "c", "d"])
    }

    @Test func switchingBackAndForthNeverCools() {
        var warm = TerminalWarmSet<String>(limit: 2)
        var cooled: [String] = []
        for i in 0..<20 { cooled += warm.touch(i % 2 == 0 ? "t1" : "t2") }
        #expect(cooled.isEmpty)
        #expect(warm.contains("t1") && warm.contains("t2"))
    }

    @Test func showingAWarmTabMakesItMostRecent() {
        var warm = TerminalWarmSet<String>(limit: 3)
        _ = warm.touch("a"); _ = warm.touch("b"); _ = warm.touch("c")
        #expect(warm.touch("a") == [])
        // "b" is now the least recent, so it goes first.
        #expect(warm.touch("d") == ["b"])
        #expect(warm.order == ["c", "a", "d"])
    }

    @Test func theShownTabIsNeverCooledAndClosedTabsLeave() {
        var warm = TerminalWarmSet<String>(limit: 1)
        #expect(warm.touch("a") == [])
        #expect(warm.touch("a") == [])
        #expect(warm.touch("b") == ["a"])
        warm.remove("b")
        #expect(warm.order.isEmpty)
        #expect(TerminalWarmSet<String>(limit: 0).limit == 1)
    }
}
