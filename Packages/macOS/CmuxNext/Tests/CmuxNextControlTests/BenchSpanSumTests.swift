#if DEBUG
import CmuxNextControl
import Testing

/// `main_thread_spans_ms` of a bench reply (``BenchSpanSum``): the sum of the spans of the bench's window,
/// without the spans of the sidebar's work. Those spans are in the reply's span list for the reader that
/// wants them; the sum keeps the meaning that it had before the app recorded them.
@Suite struct BenchSpanSumTests {
    @Test func theSumLeavesOutTheSpansOfTheSidebarsWork() {
        let spans: [(name: String, milliseconds: Double)] = [
            (name: "key.cmd-t", milliseconds: 2),
            (name: "sidebar.pass", milliseconds: 4),
            (name: "tab.insert", milliseconds: 8),
            (name: "sidebar.pendingRow.show", milliseconds: 16),
            (name: "sidebar.pendingRow.render", milliseconds: 32),
        ]
        #expect(BenchSpanSum(spans).mainThread == 10)
    }

    @Test func aNameThatOnlyHoldsTheWordIsInTheSum() {
        let spans: [(name: String, milliseconds: Double)] = [
            (name: "window.sidebar.toggle", milliseconds: 3),
            (name: "sidebars", milliseconds: 5),
        ]
        #expect(BenchSpanSum(spans).mainThread == 8)
    }

    @Test func noSpanGivesZero() {
        #expect(BenchSpanSum([]).mainThread == 0)
    }
}
#endif
