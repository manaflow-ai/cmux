import AppKit
import CmuxNextActions
import CmuxNextBrowserImport
@testable import CmuxNextComputerUse
@testable import CmuxNextCookieImport
@testable import CmuxNextImportCards
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Foundation
import Testing

/// p06-scheduler-346 (rule 9): one case per migrated owner class of the remaining targets' sweep.
///
/// - The cookie consent panel's answer is one outcome the import awaits off main: a panel that goes away without an
///   answer denies, and the first answer is the only one.
/// - The Computer Use helper v2's ready line races its limit through the `Deadline` helper: a helper that never says
///   ready is given up at the limit, and a ready line answers with no wait for the limit.
/// - The import cards follow cmux coming forward through the app's one AppEvents fan-out, not an observer of their own.
@MainActor @Suite(.timeLimit(.minutes(1))) struct RemainingTargetsSchedulerSweepTests {
    private static func request() -> CookieImportRequest {
        CookieImportRequest(requester: CookieImportRequester(kind: .agentChat, name: "Claude"), reason: "sign in to GitHub",
                            source: "Chrome", sourceIsSafari: false, domains: ["github.com"], target: "Default")
    }

    private static func deadlines() -> MainDeadlineScheduler {
        MainDeadlineScheduler(work: MainWorkScheduler(budget: MainFrameBudget()))
    }

    @Test func aConsentPanelThatGoesAwayWithoutAnAnswerDenies() async {
        let answer = FirstOutcome<CookieImportAnswer>()
        var panel: CookieImportConsentPanel? = CookieImportConsentPanel(request: Self.request(), deadlines: Self.deadlines(),
                                                                       answer: answer, onShowRequester: nil)
        #expect(panel != nil)
        panel = nil
        #expect(await answer.value() == .deny)
    }

    @Test func theConsentPanelsFirstAnswerIsTheOnlyOne() async {
        let answer = FirstOutcome<CookieImportAnswer>()
        let panel = CookieImportConsentPanel(request: Self.request(), deadlines: Self.deadlines(), answer: answer, onShowRequester: nil)
        panel.answer(.allow)
        panel.answer(.deny)
        panel.answer(.timedOut)
        #expect(await answer.value() == .allow)
        withExtendedLifetime(panel) {}
    }

    @Test func aHelperThatNeverSaysReadyIsGivenUpAtItsLimit() async throws {
        let clock = ManualClock()
        let (lines, feed) = AsyncStream<Data>.makeStream()
        let child = ComputerUseHelperV2Child(pid: 0, input: -1, lines: lines)
        let ready = Task { await ComputerUseHelperV2.readySocket(of: child, within: .seconds(5), clock: clock) }
        try await clock.waitForSleeper()
        clock.advance(by: .seconds(4))
        // A line that is not `ready` does not answer.
        feed.yield(Data(#"{"type":"log"}"#.utf8))
        clock.advance(by: .seconds(1))
        #expect(await ready.value == nil)
        feed.finish()
    }

    @Test func aReadyLineAnswersWithItsSocketWithoutWaitingForTheLimit() async {
        let (lines, feed) = AsyncStream<Data>.makeStream()
        let child = ComputerUseHelperV2Child(pid: 0, input: -1, lines: lines)
        feed.yield(Data(#"{"type":"ready","socket":"/tmp/h.sock"}"#.utf8))
        // The limit is an hour on a clock nobody advances: only the line can answer.
        let socket = await ComputerUseHelperV2.readySocket(of: child, within: .seconds(3600), clock: ManualClock())
        #expect(socket == "/tmp/h.sock")
        feed.finish()
    }

    @Test func theCardsFollowCmuxComingForwardThroughTheAppsOneFanOut() throws {
        let suite = "import-cards-events-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let ledger = FileManager.default.temporaryDirectory.appending(path: "import-jobs-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: ledger) }
        let events = AppEvents(center: NotificationCenter())
        let center = ImportSuggestionsCenter(defaults: defaults, ledgerURL: ledger)
        center.scanThisMac = { _ in [] }
        let host = ImportCardsHost(runImport: { _, _, _ in throw CancellationError() }, importedProfiles: { [] }, openSettings: { _ in },
                                   importClassic: { _ in nil }, appEvents: events)
        let registry = ActionRegistry(catalog: ActionCatalog.all, aliases: ActionCatalog.legacyAliases)
        center.start(host: host, registry: registry)
        center.start(host: host, registry: registry)
        #expect(events.subscriberCount(NSApplication.didBecomeActiveNotification) == 1)
        #expect(events.isObserving(NSApplication.didBecomeActiveNotification))
    }
}
