@testable import CmuxNextApp
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
        #expect(ChangelogPageTab.route(from: nil, to: nil, design: .sheet) == nil)
        #expect(ChangelogPageTab.route(from: "1.0.0-nightly.1", to: "1.0.0-nightly.2", design: .sheet)
            == "#/?from=1.0.0-nightly.1&to=1.0.0-nightly.2")
    }

    @Test func theLedgerIsAskedForByName() {
        #expect(ChangelogPageTab.route(from: nil, to: nil, design: .ledger) == "#/?design=ledger")
    }

    @Test func theJournalIsAskedForByName() {
        #expect(ChangelogPageTab.route(from: nil, to: nil, design: .journal) == "#/?design=journal")
    }
}
