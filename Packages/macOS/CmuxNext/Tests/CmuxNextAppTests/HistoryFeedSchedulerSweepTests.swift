import AppKit
@testable import CmuxNextBrowser
import CmuxNextBrowserHistory
import CmuxNextDesign
@testable import CmuxNextFeed
@testable import CmuxNextHistory
import CmuxNextWakeups
import Foundation
import Observation
import Testing

/// The History, BrowserHistory, Feed, Cloud, Server and Screenshots targets' sweep
/// (plans/cmux-next/chrome-parity/p06-scheduler.md, task p06-scheduler-344, rule 9): one case per migrated owner
/// class. A page's record and history writes follow it as background service observations that still run with no
/// page on screen, and a record another client moved flushes as automation; every history writer shares the app's
/// one resign-active observer; a held page's history budget is a visible deadline that the read's answer drops; the
/// Feed, History and Stashed pages resolve a theme change of a hidden page once, on show, and the Stashed page's
/// paste box still closes when the page hides. GitHubFeedSourcePollTests has the poll's background deadline and its
/// hidden-app alignment, CloudLinkReconnectingTests the link's posted redial state, CmuxNextScreenshotsTests'
/// ScreenshotsSchedulerSweepTests the Screenshots pane.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct HistoryFeedSchedulerSweepTests {
    // MARK: Service observations: the record and history writers (R-obs)

    /// A scheduler whose posted turns the test never runs: a flush shows as a posted task of its class.
    private static func heldWork() -> MainWorkScheduler {
        MainWorkScheduler.testing(ledger: WakeupLedger(), performTurn: { _ in }) { _ in nil }
    }

    /// A page change is one background task, however many changes come before it runs; nothing applies inline.
    @Test func aPageChangeFlushesTheRecordWriterAsOneBackgroundTask() {
        let work = Self.heldWork()
        let page = MockBrowserEngine().makeMockTab(BrowserTabConfiguration(initialURL: URL(string: "https://old.example/")))
        let writer = BrowserRecordWriter(tab: page, recorded: BrowserRecord(url: "https://old.example/", title: "Old"),
                                         delay: .milliseconds(500), sleep: { _ in }, mainWork: work, send: { _ in true })
        defer { writer.cancel() }
        #expect(work.postedCount(.background) == 0)
        for tick in 0..<20 { page.simulate(.titleChanged("tick \(tick)")) }
        #expect(work.postedCount(.background) == 1, "20 changes posted \(work.postedCount(.background)) flushes")
        #expect(work.postedCount(.visible) == 0 && work.postedCount(.userBlocking) == 0, "a write nobody sees took a visible class")
    }

    /// A record another client moved (`workspace.open_url`) flushes in the automation class.
    @Test func aDaemonRecordChangeFlushesAsAutomation() {
        let work = Self.heldWork()
        let page = MockBrowserEngine().makeMockTab(BrowserTabConfiguration(initialURL: URL(string: "https://old.example/")))
        let box = RecordBox(BrowserRecord(url: "https://old.example/"))
        let writer = BrowserRecordWriter(tab: page, recorded: BrowserRecord(url: "https://old.example/"),
                                         daemonRecord: { box.record }, delay: .milliseconds(500), sleep: { _ in }, mainWork: work,
                                         send: { _ in true })
        defer { writer.cancel() }
        box.record = BrowserRecord(url: "https://new.example/")
        #expect(work.postedCount(.automation) == 1)
        #expect(work.postedCount(.background) == 0, "the record change ran as the page's own write")
    }

    /// Every page's history writer saves when the app resigns active through the app's one observer: N writers are N
    /// subscriptions of one NotificationCenter observer, and one post is one delivery.
    @Test func historyWritersShareTheAppsOneResignObserver() {
        let center = NotificationCenter()
        let events = AppEvents(center: center)
        let work = Self.heldWork()
        let writers = (0..<3).map { _ in
            BrowserHistoryWriter(page: MockBrowserEngine(kind: .cef).makeMockTab(BrowserTabConfiguration(initialURL: URL(string: "https://example.com/"))),
                                 recorded: nil, delay: .seconds(3600), sleep: { _ in }, mainWork: work, appEvents: events,
                                 send: { _ in true })
        }
        let name = NSApplication.didResignActiveNotification
        #expect(events.subscriberCount(name) == 3)
        #expect(events.isObserving(name))
        center.post(name: name, object: nil)
        #expect(events.deliveries(name) == 1, "each writer observed the notice itself")
        for writer in writers { writer.cancel() }
        #expect(events.subscriberCount(name) == 0, "a cancelled writer kept its subscription")
    }

    // MARK: Deadline: a held page's history budget (R-timer)

    /// A held page's budget is a visible deadline: when it fires the page loads its address; the read's answer first
    /// drops it, so its wake does nothing.
    @Test func aHeldPagesBudgetIsADeadlineTheReadsAnswerDrops() throws {
        _ = NSApplication.shared
        let rig = MainDeadlineRig()
        let starts = BrowserHistoryStarts(deadlines: rig.deadlines)
        let page = WebKitEngine(fileInput: NoFileInput(), stores: .inMemory()).makeWebKitTab()
        defer { page.close() }
        let url = try #require(URL(string: "about:blank"))

        starts.hold(page, url: url, tabID: "slow")
        #expect(rig.hasArmedWake, "the budget armed no wake")
        #expect(starts.outcomes["slow"] == nil)
        rig.fireAndRun()
        #expect(rig.elapsed >= 1, "the budget fired \(rig.elapsed) s in, before its 1 s")
        #expect(starts.outcomes["slow"] == "address", "a slow read kept the page blank")

        let answered = WebKitEngine(fileInput: NoFileInput(), stores: .inMemory()).makeWebKitTab()
        defer { answered.close() }
        starts.hold(answered, url: url, tabID: "fast")
        #expect(rig.hasArmedWake)
        starts.start("fast", saved: nil)
        #expect(!rig.hasArmedWake, "the answered read's budget kept its wake")
    }

    // MARK: Hidden: the Feed, History and Stashed pages (R-appear, R-hide)

    /// A host in a window whose node reads visible (the window is never ordered in): its node follows only its own hide.
    private static func shownWindow(_ content: NSView) -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 480), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        _ = WindowVisibilitySource.of(window, read: { _ in .visible })
        window.contentView = content
        return window
    }

    @Test func aThemeChangeOfAHiddenFeedResolvesItsColorsOnceOnShow() {
        let host = FeedHostView(model: FeedModel(source: MockFeedSource()), mainWork: linklessMainWork())
        let window = Self.shownWindow(host)
        defer { window.contentView = nil; window.close() }
        Self.expectOneResolveOnShow(host, resolves: { host.colorResolves }, "feed")
    }

    @Test func aThemeChangeOfAHiddenStashedPageResolvesItsColorsOnceOnShow() {
        let host = StashPageHostView(model: StashPageModel(), draft: StashImportDraft())
        let window = Self.shownWindow(host)
        defer { window.contentView = nil; window.close() }
        Self.expectOneResolveOnShow(host, resolves: { host.colorResolves }, "stashed page")
    }

    /// The Stashed page's paste box closes when the page hides (its node's own hide), as when it closes.
    @Test func hidingTheStashedPageClosesItsPasteBox() {
        let draft = StashImportDraft()
        let host = StashPageHostView(model: StashPageModel(), draft: draft)
        let window = Self.shownWindow(host)
        defer { window.contentView = nil; window.close() }
        draft.open()
        draft.text = "https://example.com | Example"
        host.isHidden = true
        #expect(!draft.isOpen, "the hidden page kept its paste box open")
        #expect(draft.text.isEmpty)
    }

    private static func expectOneResolveOnShow(_ host: NSView, resolves: () -> Int, _ what: String) {
        let shown = resolves()
        host.viewDidChangeEffectiveAppearance()
        #expect(resolves() == shown + 1, "a shown \(what) did not resolve its colors on a theme change")
        host.isHidden = true
        let hidden = resolves()
        host.viewDidChangeEffectiveAppearance()
        host.viewDidChangeEffectiveAppearance()
        #expect(resolves() == hidden, "a hidden \(what) resolved its colors")
        host.isHidden = false
        #expect(resolves() == hidden + 1, "the show resolved the hidden theme changes \(resolves() - hidden) times (want 1)")
    }
}

/// A tab's daemon record another client can move.
@MainActor @Observable private final class RecordBox {
    var record: BrowserRecord?
    init(_ record: BrowserRecord?) { self.record = record }
}
