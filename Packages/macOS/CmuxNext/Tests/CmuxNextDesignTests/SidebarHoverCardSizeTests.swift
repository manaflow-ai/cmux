import CmuxNextDesign
import Testing

/// The sidebar's workspace hover card stays small beside the rows it opens from (Leo 2026-11-12: "the hover previews
/// for the sidebar are still just too big"). At a 12 pt title: 232 pt wide by default, 280 pt at its widest, and six
/// rows of history before it scrolls.
struct SidebarHoverCardSizeTests {
    typealias M = SidebarHoverCardMetrics

    @Test func theDefaultCardIsNarrowerThanBefore() {
        #expect(M.textColumnInTitles <= 18, "the default card is \(M.textColumnInTitles) titles wide")
        #expect(M.maxTextColumnInTitles <= 22, "the widest card is \(M.maxTextColumnInTitles) titles wide")
        #expect(M.minTextColumnInTitles <= M.textColumnInTitles && M.textColumnInTitles <= M.maxTextColumnInTitles)
    }

    @Test func theHistoryIsShorterThanBefore() {
        #expect(M.timelineRows <= 6, "the history shows \(M.timelineRows) rows before it scrolls")
        #expect(M.timelineRows < M.logRows, "the full history is no taller than the default card")
    }
}
