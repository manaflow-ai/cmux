import Testing

@testable import CmuxBrowser

/// A page controls how many resource loads it leaves unfinished (requests
/// that never get an answer) and how long their URLs and headers are; the
/// driver holds each one's request until it ends.
@Suite("Browser REPL unfinished resource loads")
struct BrowserReplUnfinishedLoadsTests {
    @Test("Past 1,000 unfinished loads the oldest is dropped, and its end says so")
    func countIsBounded() {
        var loads = BrowserReplUnfinishedLoads<String>()
        for id in 0..<1_001 { loads.start(UInt64(id), "request \(id)", bytes: 100) }
        #expect(loads.count == 1_000)
        let oldest = loads.finish(0)
        #expect(oldest.value == nil && oldest.dropped)
        let newest = loads.finish(1_000)
        #expect(newest.value == "request 1000" && !newest.dropped)
        // A load that ended is not dropped later, and one never seen was not dropped.
        #expect(loads.finish(1_000).dropped == false)
        #expect(loads.finish(5_000).dropped == false)
    }

    @Test("Past 8 MiB of held requests the oldest are dropped, also when a response grows one")
    func bytesAreBounded() {
        var loads = BrowserReplUnfinishedLoads<Int>()
        let quarter = 2 << 20
        for id in 0..<4 { loads.start(UInt64(id), id, bytes: quarter) }
        #expect(loads.count == 4)
        loads.start(4, 4, bytes: 1)
        #expect(loads.finish(0).dropped)
        #expect(loads.value(for: 1) == 1)
        // A response's headers make load 4 large: the oldest go to make room.
        loads.update(4, 4, bytes: quarter * 3)
        #expect(loads.finish(1).dropped && loads.finish(2).dropped)
        #expect(loads.value(for: 3) == 3 && loads.value(for: 4) == 4)
        // One larger than the whole budget is not held at all.
        loads.start(9, 9, bytes: 9 << 20)
        #expect(loads.value(for: 9) == nil)
        #expect(loads.finish(9).dropped)
    }
}
