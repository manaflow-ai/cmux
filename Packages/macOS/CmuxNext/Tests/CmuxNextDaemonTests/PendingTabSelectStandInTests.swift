import CmuxNextDaemon
import Testing

/// A pane's apply asks what tab to select now (``PendingTabSelect``). With a held New Tab key, two or more stand-in
/// tabs get their tabs in one apply and the pane's strip pairs none of them. The pane then has nothing of its own to
/// take, and the answer is the tab that the selected stand-in became, by the store's record of the creation: the
/// pane selects and shows that tab in the same apply, as a tab it created.
@MainActor
struct PendingTabSelectStandInTests {
    private static let standIn = ProvisionalTab.idPrefix + "2"

    /// One ask with nothing that waits: the pane selects `selected`, its strip lists `listed`, and the record says
    /// `fate` of each stand-in.
    private static func taken(selected: String?, listed: Set<String>, fate: StandInFate) -> String? {
        var pending = PendingTabSelect()
        return pending.take(shown: [], record: [], selected: selected, listed: { listed.contains($0) }, fate: { _ in fate })
    }

    @Test func theTabOfTheSelectedStandInIsTakenWhenTheStripListsIt() {
        #expect(Self.taken(selected: Self.standIn, listed: ["a", "t1", "t2"], fate: .became("t2")) == "t2")
    }

    /// Nothing is taken in each other case: the selection stays, or the close rule picks.
    @Test func nothingIsTakenInAnyOtherCase() {
        // The strip still lists the stand-in.
        #expect(Self.taken(selected: Self.standIn, listed: ["a", Self.standIn, "t2"], fate: .became("t2")) == nil)
        // The strip does not list its tab yet.
        #expect(Self.taken(selected: Self.standIn, listed: ["a", "t1"], fate: .became("t2")) == nil)
        // Its creation is still under way, or it ended (closed by the person, refused or failed).
        #expect(Self.taken(selected: Self.standIn, listed: ["a", "t1", "t2"], fate: .underway) == nil)
        #expect(Self.taken(selected: Self.standIn, listed: ["a", "t1", "t2"], fate: .ended) == nil)
        // The selected tab is a daemon's tab that left the strip: a close.
        #expect(Self.taken(selected: "b", listed: ["a", "t1", "t2"], fate: .became("t2")) == nil)
        // The pane selects nothing.
        #expect(Self.taken(selected: nil, listed: ["a", "t1", "t2"], fate: .became("t2")) == nil)
    }
}
