import CmuxNextAgentPane
import CmuxNextSettings
@testable import CmuxNextUpdater
import Foundation
import Testing

/// The sidebar's "Did you know?" card shows tips as rarely as the agent chat's feature tips: at most
/// one tip every 14 days across both (one shared record, `FeatureTipBudget`), each tip once, never
/// about an action already run, and an install that ran before tips never sees the basics (Leo,
/// 2026-10-30: "no this should be very very infrequent like app installation level frequent and if
/// they havent used the browser"). Before this, the card picked a new tip every calendar day and a
/// long-used install still got "Split panes".
@MainActor @Suite(.serialized) struct TipChooserCadenceTests {
    private let catalog = [
        Tip(id: "a", action: "actionA", title: "A", benefit: "a"),
        Tip(id: "b", action: "actionB", title: "B", benefit: "b"),
        Tip(id: "c", action: "actionC", title: "C", benefit: "c"),
    ]
    private let day = 86_400.0
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func defaults() throws -> UserDefaults {
        let suite = "TipChooserCadenceTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    // MARK: TipChooser (pure)

    @Test func aClosedBudgetPicksNoNewTip() {
        let (tip, state) = TipChooser.choose(catalog, state: TipState(), today: "2026-11-01", budgetOpen: false)
        #expect(tip == nil)
        #expect(state == TipState())
    }

    @Test func anOpenBudgetPicksTheFirstUnusedUnseenTip() {
        let state = TipState(usedActions: ["actionA"])
        let (tip, next) = TipChooser.choose(catalog, state: state, today: "2026-11-01", budgetOpen: true)
        #expect(tip?.id == "b")
        #expect(next.shownTip == "b")
    }

    /// The day after a tip was seen, the old chooser picked the next tip; the spent budget now holds it.
    @Test func noTipTheDayAfterOneWasSeen() {
        var state = TipState(shownTip: "a", shownDay: "2026-11-01")
        state.seen = ["a"]
        let lastShown = start
        for offset in 1..<FeatureTipBudget.minimumDaysBetweenTips {
            let date = start.addingTimeInterval(Double(offset) * day)
            let open = FeatureTipBudget.isOpen(lastShownAt: lastShown, at: date)
            let (tip, _) = TipChooser.choose(catalog, state: state, today: TipState.day(date), budgetOpen: open)
            #expect(tip == nil, "day \(offset)")
        }
        let later = start.addingTimeInterval(Double(FeatureTipBudget.minimumDaysBetweenTips) * day)
        let (tip, _) = TipChooser.choose(catalog, state: state, today: TipState.day(later),
                                         budgetOpen: FeatureTipBudget.isOpen(lastShownAt: lastShown, at: later))
        #expect(tip?.id == "b")
    }

    /// A tip chosen today but not on screen yet waits for the budget too: a feature tip that showed
    /// since takes the turn.
    @Test func todaysUnseenTipYieldsToAClosedBudget() {
        let state = TipState(shownTip: "a", shownDay: "2026-11-01")
        #expect(TipChooser.choose(catalog, state: state, today: "2026-11-01", budgetOpen: true).tip?.id == "a")
        #expect(TipChooser.choose(catalog, state: state, today: "2026-11-01", budgetOpen: false).tip == nil)
    }

    /// The tip on the card stays for the day although it spent the budget.
    @Test func theTipOnTheCardStaysForTheDay() {
        var state = TipState(shownTip: "a", shownDay: "2026-11-01")
        state.seen = ["a"]
        let (tip, _) = TipChooser.choose(catalog, state: state, today: "2026-11-01", showing: "a", budgetOpen: false)
        #expect(tip?.id == "a")
    }

    @Test func anExistingInstallCountsTheCatalogAsUsed() {
        let settled = TipChooser.settleInstall(TipState(), catalog: catalog, install: "existing")
        #expect(settled.installSettled)
        #expect(settled.usedActions == ["actionA", "actionB", "actionC"])
        #expect(TipChooser.choose(catalog, state: settled, today: "2026-11-01", budgetOpen: true).tip == nil)
        // A tip a later release adds still shows once: settling happens once.
        let grown = catalog + [Tip(id: "d", action: "actionD", title: "D", benefit: "d")]
        let again = TipChooser.settleInstall(settled, catalog: grown, install: "existing")
        #expect(again == settled)
        #expect(TipChooser.choose(grown, state: again, today: "2026-11-01", budgetOpen: true).tip?.id == "d")
    }

    @Test func aFreshInstallKeepsEveryTip() {
        let settled = TipChooser.settleInstall(TipState(), catalog: catalog, install: "fresh")
        #expect(settled.installSettled && settled.usedActions.isEmpty)
        #expect(TipChooser.settleInstall(TipState(), catalog: catalog, install: nil) == TipState())
    }

    // MARK: The card and the feature tips share one budget

    private func updater(_ defaults: UserDefaults, at clock: @escaping () -> Date) -> UpdaterService {
        let updater = UpdaterService(defaults: defaults, enableSparkle: false, recordsUpdates: false, now: clock)
        updater.tipsEnabled = true
        return updater
    }

    /// Leo's case: an install that ran before tips gets no basics tip on the card.
    @Test func anExistingInstallSeesNoCardTip() throws {
        let defaults = try defaults()
        AgentPaneFeatureTipRecords(defaults: defaults).settleInstall(launchedBefore: true)
        let updater = updater(defaults) { self.start }
        updater.refreshTip(at: start)
        #expect(updater.tip == nil)
        #expect(TipState(defaults: defaults).usedActions.isSuperset(of: TipCatalog.all.map(\.action)))
    }

    /// A card tip on screen spends the shared budget: the next day's card and the agent chat's
    /// Browser tip both wait 14 days.
    @Test func aSeenCardTipHoldsEveryTipForFourteenDays() throws {
        let defaults = try defaults()
        let records = AgentPaneFeatureTipRecords(defaults: defaults) { self.start.addingTimeInterval(self.day) }
        records.settleInstall(launchedBefore: false)
        let updater = updater(defaults) { self.start }
        updater.refreshTip(at: start)
        let first = try #require(updater.tip)
        updater.tipCardAction(first.id, UpdaterService.tipShownAction)
        #expect(FeatureTipBudget(defaults: defaults).lastShownAt == start)

        #expect(!records.claim("agents-drive-visible-browser-tabs", feature: AgentPaneFeatureTipRecords.browserFeature))
        updater.refreshTip(at: start.addingTimeInterval(day))
        #expect(updater.tip == nil)
        updater.refreshTip(at: start.addingTimeInterval(13 * day))
        #expect(updater.tip == nil)
        updater.refreshTip(at: start.addingTimeInterval(14 * day))
        #expect(updater.tip != nil && updater.tip?.id != first.id)
    }

    /// A feature tip the agent chat showed holds the card for 14 days.
    @Test func aFeatureTipHoldsTheCard() throws {
        let defaults = try defaults()
        let records = AgentPaneFeatureTipRecords(defaults: defaults) { self.start }
        records.settleInstall(launchedBefore: false)
        #expect(records.claim("agents-drive-visible-browser-tabs", feature: AgentPaneFeatureTipRecords.browserFeature))
        let updater = updater(defaults) { self.start }
        updater.refreshTip(at: start.addingTimeInterval(2 * day))
        #expect(updater.tip == nil)
        updater.refreshTip(at: start.addingTimeInterval(14 * day))
        #expect(updater.tip != nil)
    }
}
