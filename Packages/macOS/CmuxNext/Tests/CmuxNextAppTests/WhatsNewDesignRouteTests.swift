@testable import CmuxNextApp
import Testing

/// u5099 (2026-10-20): the What's New page opens in the Conductor-style Ledger design by default
/// (design/changelog-variations-gallery, #01). The default route carries no `design=`; the older
/// designs stay reachable from Debug Settings `whatsNew.design`.
@Suite
struct WhatsNewDesignRouteTests {
    @Test func theLedgerIsTheDefaultDesign() {
        #expect(WhatsNewTunables.design.defaultValue == .ledger)
    }

    @Test func theDefaultDesignOpensWithNoRoute() {
        #expect(ChangelogPageTab.route(from: nil, to: nil, design: .ledger) == nil)
        #expect(ChangelogPageTab.route(from: "1.0.0-nightly.1", to: "1.0.0-nightly.2", design: .ledger)
            == "#/?from=1.0.0-nightly.1&to=1.0.0-nightly.2")
    }

    @Test func theJournalIsAskedForByName() {
        #expect(ChangelogPageTab.route(from: nil, to: nil, design: .journal) == "#/?design=journal")
    }
}
