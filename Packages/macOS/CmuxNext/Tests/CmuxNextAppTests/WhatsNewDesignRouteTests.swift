@testable import CmuxNextApp
import CmuxNextPages
import CmuxNextUpdater
import Testing

/// 2026-10-31 (Lawrence, "what's new page looks bad"): the What's New page opens as the What's New
/// sheet by default (cmux-shots/whatsnew-variations); before it the Conductor-style Ledger (u5099).
/// The default route carries no `design=`; the Ledger and the older designs stay reachable from
/// Debug Settings `whatsNew.design`.
@Suite
struct WhatsNewDesignRouteTests {
    @Test func theSheetIsTheDefaultDesign() {
        #expect(WhatsNewTunables.design.defaultValue == .sheet)
    }

    @Test func theDefaultDesignOpensWithNoRoute() {
        #expect(WhatsNewDesign.sheet.changelogRoute(from: nil, to: nil) == nil)
        #expect(WhatsNewDesign.sheet.changelogRoute(from: "1.0.0-nightly.1", to: "1.0.0-nightly.2")
            == "#/?from=1.0.0-nightly.1&to=1.0.0-nightly.2")
    }

    @Test func theLedgerIsAskedForByName() {
        #expect(WhatsNewDesign.ledger.changelogRoute(from: nil, to: nil) == "#/?design=ledger")
    }

    @Test func theJournalIsAskedForByName() {
        #expect(WhatsNewDesign.journal.changelogRoute(from: nil, to: nil) == "#/?design=journal")
    }

    /// A row of the sidebar Updated card's list opens the page at its change (Leo, 2026-11-08:
    /// "maybe just bring them to the section in what's new"); the nonce makes a second click a new route.
    @Test func aFocusedChangeRidesTheRoute() throws {
        let focus = try #require(ChangelogFocus(area: "agentChat", entry: "Faster chat a+b", nonce: "k1"))
        #expect(WhatsNewDesign.sheet.changelogRoute(from: "0.9.0", to: "1.0.0", focus: focus)
            == "#/?from=0.9.0&to=1.0.0&area=agentChat&entry=Faster%20chat%20a%2Bb&n=k1")
        #expect(WhatsNewDesign.sheet.changelogRoute(from: nil, to: nil, focus: ChangelogFocus(area: "agentChat", entry: nil, nonce: "k2"))
            == "#/?area=agentChat&n=k2")
        #expect(ChangelogFocus(area: "", entry: nil) == nil, "the card's own link carries no focus")
    }
}
