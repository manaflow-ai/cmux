@testable import CmuxNextApp
import CmuxNextSettings
import CmuxNextSidebar
import CmuxNextTestSupport
@testable import CmuxNextUpdater
import Foundation
import Testing

/// The sidebar asks the person once, ever, to star cmux on GitHub (Lawrence 2026-11-15: "we need to prompt
/// user to star cmux ono github, that they can x out as well ... we should remember and dont prompt that
/// multiple times tho"). Only after real use (``StarPromptCenter/minimumDays`` days since the first launch and
/// ``StarPromptCenter/minimumLaunches`` launches), never beside another tip, and done for good once its x or
/// its button is pressed, or once it was on screen for a whole launch.
@MainActor @Suite(.serialized) struct StarPromptOnceTests {
    private let day = 86_400.0
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func defaults() throws -> UserDefaults {
        let suite = "StarPromptOnceTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(testSuiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    /// `launches` launches, the first at `start`, one a day.
    private func launched(_ launches: Int, _ defaults: UserDefaults, lastAt: Date? = nil) -> StarPromptCenter {
        var center = StarPromptCenter(defaults: defaults) { self.start }
        for index in 0..<launches {
            let at = index == launches - 1 ? (lastAt ?? start.addingTimeInterval(Double(index) * day)) : start.addingTimeInterval(Double(index) * day)
            center = StarPromptCenter(defaults: defaults) { at }
            center.recordLaunch()
        }
        return center
    }

    // MARK: The eligibility gate

    @Test func theFirstLaunchNeverAsks() throws {
        let center = launched(1, try defaults())
        center.refresh(budgetOpen: true)
        #expect(!center.isOffered)
    }

    @Test func fiveLaunchesInOneDayDoNotAsk() throws {
        let center = launched(5, try defaults(), lastAt: start.addingTimeInterval(2 * 3_600))
        center.refresh(budgetOpen: true)
        #expect(!center.isOffered)
    }

    @Test func threeDaysWithFourLaunchesDoNotAsk() throws {
        let center = launched(4, try defaults(), lastAt: start.addingTimeInterval(10 * day))
        center.refresh(budgetOpen: true)
        #expect(!center.isOffered)
    }

    @Test func threeDaysAndFiveLaunchesAsk() throws {
        let center = launched(5, try defaults(), lastAt: start.addingTimeInterval(3 * day))
        center.refresh(budgetOpen: true)
        #expect(center.isOffered)
    }

    /// A tip showed in the last 14 days (the shared budget): the star prompt waits, so no two asks come close.
    @Test func aRecentTipHoldsTheAsk() throws {
        let center = launched(5, try defaults(), lastAt: start.addingTimeInterval(4 * day))
        center.refresh(budgetOpen: false)
        #expect(!center.isOffered)
    }

    // MARK: Once, ever

    @Test(arguments: [false, true])
    func theXOrTheButtonEndsItForGood(starred: Bool) throws {
        let defaults = try defaults()
        let center = launched(5, defaults, lastAt: start.addingTimeInterval(3 * day))
        center.refresh(budgetOpen: true)
        #expect(center.isOffered)
        center.markShown()
        if starred { center.starred() } else { center.dismiss() }
        #expect(!center.isOffered)
        center.refresh(budgetOpen: true)
        #expect(!center.isOffered)

        let later = StarPromptCenter(defaults: defaults) { self.start.addingTimeInterval(400 * self.day) }
        for _ in 0..<20 { later.recordLaunch() }
        later.refresh(budgetOpen: true)
        #expect(!later.isOffered)
        #expect(later.isDone)
    }

    /// Shown and left alone for a whole launch: the next launch never shows it again.
    @Test func aWholeLaunchOnScreenEndsIt() throws {
        let defaults = try defaults()
        let center = launched(5, defaults, lastAt: start.addingTimeInterval(3 * day))
        center.refresh(budgetOpen: true)
        center.markShown()
        center.refresh(budgetOpen: true)
        #expect(center.isOffered, "it stays for the rest of the launch it showed in")

        let next = StarPromptCenter(defaults: defaults) { self.start.addingTimeInterval(5 * self.day) }
        next.recordLaunch()
        next.refresh(budgetOpen: true)
        #expect(!next.isOffered)
        #expect(next.isDone)
    }

    /// Offered but never on screen (another card had the slot all launch): it may still ask later.
    @Test func offeredButNeverShownStaysPending() throws {
        let defaults = try defaults()
        let center = launched(5, defaults, lastAt: start.addingTimeInterval(3 * day))
        center.refresh(budgetOpen: true)
        let next = StarPromptCenter(defaults: defaults) { self.start.addingTimeInterval(4 * self.day) }
        next.recordLaunch()
        next.refresh(budgetOpen: true)
        #expect(next.isOffered)
    }

    // MARK: The sidebar card

    private func updater(_ defaults: UserDefaults, at date: Date) -> UpdaterService {
        let updater = UpdaterService(defaults: defaults, enableSparkle: false, recordsUpdates: false, now: { date })
        updater.tipsEnabled = true
        return updater
    }

    /// The prompt is the bottom-left notice card, with one button and a plain x; no tip shows beside it.
    @Test func theCardAsksOnceWithOneButtonAndAnX() throws {
        let defaults = try defaults()
        _ = launched(5, defaults, lastAt: start.addingTimeInterval(3 * day))
        let updater = updater(defaults, at: start.addingTimeInterval(3 * day))
        updater.refreshTip()
        let card = try #require(SidebarCardFeed.noticeCard(updater, registry: nil))
        #expect(card.id == UpdaterService.starCardID)
        #expect(card.actions.map(\.id) == [UpdaterService.starOpenAction])
        #expect(card.dismissLabel != nil)
        #expect(card.dismissMenu.isEmpty)
        #expect(card.shownAction == UpdaterService.tipShownAction)
        #expect(updater.tip == nil)

        updater.starCardAction(UpdaterService.tipShownAction)
        #expect(FeatureTipBudget(defaults: defaults).lastShownAt == start.addingTimeInterval(3 * day), "it spends the tips' budget")
        updater.starPromptFinished(starred: false)
        #expect(SidebarCardFeed.noticeCard(updater, registry: nil) == nil)
        #expect(StarPromptCenter(defaults: defaults) { Date() }.isDone)
    }

    /// Its button opens the repository page in the browser, once, and ends the ask.
    @Test func theButtonOpensTheRepository() throws {
        let defaults = try defaults()
        _ = launched(5, defaults, lastAt: start.addingTimeInterval(3 * day))
        let opened = OpenedURLs()
        let center = StarPromptCenter(defaults: defaults, now: { self.start.addingTimeInterval(3 * self.day) }) { opened.urls.append($0) }
        center.refresh(budgetOpen: true)
        center.starred()
        #expect(opened.urls.map(\.absoluteString) == ["https://github.com/manaflow-ai/cmux"])
        #expect(center.isDone && !center.isOffered)
    }

    /// Tips off (`sidebar.cards.tips`) means no asks of any kind on the card.
    @Test func tipsOffMeansNoAsk() throws {
        let defaults = try defaults()
        _ = launched(5, defaults, lastAt: start.addingTimeInterval(3 * day))
        let updater = UpdaterService(defaults: defaults, enableSparkle: false, recordsUpdates: false, now: { self.start.addingTimeInterval(3 * self.day) })
        updater.tipsEnabled = false
        updater.refreshTip()
        #expect(!updater.starPrompt.isOffered)
    }
}

/// The URLs a star card's button opened (a recorder for ``StarPromptCenter``'s `open`).
@MainActor private final class OpenedURLs {
    var urls: [URL] = []
}
