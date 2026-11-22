import Foundation
import Testing
@testable import CmuxNextUpdater

/// BOTTOM-LEFT-CARDS K1 (Lawrence 2026-10-07): a "Did you know" card shows
/// one tip at a time for a feature the user has not used, at most one new
/// tip a day, dismissable per tip, off with `sidebar.cards.tips`; usage
/// flags stay on this Mac. Before, the bottom-left showed nothing but the
/// update card.
@MainActor
@Suite struct TipCardTests {
    private let catalog = [
        Tip(id: "a", action: "actA", title: "A", benefit: "a"),
        Tip(id: "b", action: "actB", title: "B", benefit: "b"),
        Tip(id: "c", action: "actC", title: "C", benefit: "c"),
    ]

    @Test func oneTipADayInCatalogOrder() {
        var (tip, state) = TipChooser.choose(catalog, state: TipState(), today: "2026-10-07")
        #expect(tip?.id == "a")
        (tip, state) = TipChooser.choose(catalog, state: state, today: "2026-10-07")
        #expect(tip?.id == "a", "the same tip all day")
        (tip, state) = TipChooser.choose(catalog, state: state, today: "2026-10-08")
        #expect(tip?.id == "b", "the next day rotates once")
    }

    @Test func usedAndDismissedTipsNeverShowAndNothingMoreToday() {
        var state = TipState(usedActions: ["actA"])
        var tip: Tip?
        (tip, state) = TipChooser.choose(catalog, state: state, today: "2026-10-07")
        #expect(tip?.id == "b", "a used feature is skipped")
        state.dismissed.insert("b")
        (tip, state) = TipChooser.choose(catalog, state: state, today: "2026-10-07")
        #expect(tip == nil, "after a dismiss no other tip today")
        (tip, state) = TipChooser.choose(catalog, state: state, today: "2026-10-08")
        #expect(tip?.id == "c")
        state.usedActions.insert("actC")
        (tip, _) = TipChooser.choose(catalog, state: state, today: "2026-10-09")
        #expect(tip == nil, "every tip used or dismissed: no card")
    }

    private func service(_ suite: String, now: Date = Date(timeIntervalSince1970: 1_791_000_000)) -> UpdaterService {
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        return UpdaterService(identity: AppcastFixtures.identity(bundle: "com.cmuxterm.app.nightly", build: "100"),
                              policy: ManagedUpdatePolicy { false }, defaults: defaults, enableSparkle: false, now: { now })
    }

    /// The service picks the first real catalog tip, Try It runs its action
    /// as the user's and closes the card, and the usage flag, the dismissal
    /// and today's choice survive a restart (a new service on the same store).
    @Test func tryAndDismissPersistAcrossARestart() {
        let suite = "tips-\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let first = service(suite)
        first.refreshTip()
        let tip = TipCatalog.all[0]
        #expect(first.tip == tip)
        var ran: [String] = []
        first.runTipAction = { ran.append($0) }
        first.tryTip(tip.id)
        #expect(ran == [tip.action])
        #expect(first.tip == nil)

        let second = service(suite)
        second.refreshTip()
        #expect(second.tip == nil, "no second tip on the same day")
        #expect(TipState(defaults: UserDefaults(suiteName: suite) ?? .standard).usedActions.contains(tip.action))

        let nextDay = service(suite, now: Date(timeIntervalSince1970: 1_791_000_000 + 86_400))
        nextDay.refreshTip()
        let shown = TipCatalog.all[1]
        #expect(nextDay.tip == shown)
        nextDay.dismissTip(shown.id)
        #expect(nextDay.tip == nil)
        let reloaded = TipState(defaults: UserDefaults(suiteName: suite) ?? .standard)
        #expect(reloaded.dismissed == [shown.id])
    }

    @Test func turningTipsOffHidesTheCardAndOnShowsTodaysTip() {
        let suite = "tips-off-\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let service = service(suite)
        service.refreshTip()
        #expect(service.tip != nil)
        service.tipsEnabled = false
        #expect(service.tip == nil)
        service.tipsEnabled = true
        #expect(service.tip == TipCatalog.all[0])
    }

    /// The user's run of a tip's action marks it used and closes that tip.
    @Test func runningTheFeatureMarksItUsed() {
        let suite = "tips-used-\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let service = service(suite)
        service.refreshTip()
        service.markTipActionUsed(TipCatalog.all[0].action)
        #expect(service.tip == nil)
        service.markTipActionUsed("notATipAction")
        #expect(TipState(defaults: UserDefaults(suiteName: suite) ?? .standard).usedActions == [TipCatalog.all[0].action])
    }
}
