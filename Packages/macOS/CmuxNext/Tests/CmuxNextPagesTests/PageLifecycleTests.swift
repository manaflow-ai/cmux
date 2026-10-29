import AppKit
import CmuxNextCompat
import CmuxNextDesign
import CmuxNextHibernation
@testable import CmuxNextPages
import CmuxNextPagesTestSupport
import CmuxNextSettings
@testable import CmuxNextWakeups
import Foundation
import Testing
import WebKit

/// ``PageLifecycle`` takes show and hide from its caller (the content lifecycle), runs the planner
/// only at its one one-shot deadline, thaws a page before its show returns, and does O(changed pages)
/// work per event. The deadline is a real ``MainDeadline`` on a wake-up queue whose
/// timer and uptime only the test moves: a pass runs only when that wake fires.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1)))
struct PageLifecycleTests {
    /// A page that logs each step and counts reads of its keep reasons.
    private final class FakePage {
        let name: String
        let log: Log
        var reasons: Set<PageLifecyclePlanner.KeepReason> = []
        /// Its ``PageKeepReasons``, as a ``PageWebView`` holds them.
        let keep = PageKeepReasons()
        var reasonReads = 0
        /// The page refuses its discard (it still shows): the lifecycle must keep its state.
        var refusesDiscard = false
        /// The page answers a freeze with a refusal (it shows, or its engine did not freeze).
        var refusesFreeze = false
        weak var lifecycle: PageLifecycle?

        init(_ name: String, log: Log) {
            self.name = name
            self.log = log
            keep.owner = self
        }
    }

    private final class Log {
        var lines: [String] = []
        var passes = 0
    }

    private struct Target: PageLifecycleTarget {
        let page: FakePage
        var object: AnyObject? { page }
        var lifecycleGroup: String? { "privileged" }
        var lifecycleKeepReasons: Set<PageLifecyclePlanner.KeepReason> {
            page.reasonReads += 1
            return page.reasons.union(page.keep.current)
        }

        func reportsReasonChanges(to lifecycle: PageLifecycle) {
            page.lifecycle = lifecycle
            page.keep.lifecycle = lifecycle
        }
        func keepHideSnapshot() {}
        func dropHideSnapshot() {}
        func freeze() -> Bool {
            page.log.lines.append("freeze \(page.name)")
            return !page.refusesFreeze
        }
        func thaw() { page.log.lines.append("thaw \(page.name)") }
        func discard() -> Bool {
            page.log.lines.append((page.refusesDiscard ? "refuse " : "discard ") + page.name)
            return !page.refusesDiscard
        }
    }

    private let log = Log()
    private let rig = LifecycleDeadlineRig()
    private let lifecycle: PageLifecycle

    init() {
        lifecycle = PageLifecycle(deadlines: rig.scheduler)
        let log = log
        lifecycle.didRunPass = { log.passes += 1 }
    }

    private func page(_ name: String) -> FakePage { FakePage(name, log: log) }

    /// The one armed wake fires, as the run loop's timer would, then the frame the pass is posted in:
    /// one pass runs, at its due time. Nothing else runs a pass in these tests.
    private func fireDuePass(sourceLocation: SourceLocation = #_sourceLocation) throws {
        let due = try #require(lifecycle.nextPassAt, sourceLocation: sourceLocation)
        #expect(rig.queue.count == 1, "one wake pending, not a timer per page", sourceLocation: sourceLocation)
        let passes = log.passes
        rig.fire()
        #expect(log.passes == passes + 1, "the wake ran no pass", sourceLocation: sourceLocation)
        #expect(rig.now >= due, sourceLocation: sourceLocation)
    }

    private func near(_ value: Duration?, _ expected: Duration) -> Bool {
        guard let value else { return false }
        return abs((value - expected) / .milliseconds(1)) < 20
    }

    @Test func hideArmsOneDeadlineAtTheEndOfRecentlyVisibleAndNoPassRunsBefore() throws {
        let settings = page("settings")
        lifecycle.show("a", page: Target(page: settings))
        #expect(lifecycle.nextPassAt == nil)
        #expect(rig.queue.count == 0)
        rig.advance(to: .seconds(3))
        lifecycle.hide("a", page: Target(page: settings))
        #expect(lifecycle.nextPassAt == .seconds(13))
        #expect(rig.queue.count == 1)
        // The wake is not due yet: firing the queue early runs nothing.
        rig.fire(movingTime: false)
        #expect(log.passes == 0)
        #expect(settings.reasonReads == 0) // a hide plans nothing
        #expect(lifecycle.state(of: "a") == .hidden)
    }

    @Test func theOnlyHiddenPageIsMostRecentlyUsedSoItIsNotFrozenThenDiscardedOnItsDeadline() throws {
        let settings = page("settings")
        lifecycle.show("a", page: Target(page: settings))
        lifecycle.hide("a", page: Target(page: settings))
        try fireDuePass()
        #expect(lifecycle.state(of: "a") == .hidden)
        #expect(log.lines.isEmpty)
        // One deadline at a time: the discard at 300 s, not a repeating tick.
        #expect(near(lifecycle.nextPassAt, .seconds(300)))
        #expect(rig.queue.count == 1)
        try fireDuePass()
        #expect(lifecycle.state(of: "a") == .discarded)
        #expect(log.lines == ["discard settings"])
        #expect(lifecycle.nextPassAt == nil)
        #expect(rig.queue.count == 0, "a one-shot deadline: nothing left armed")
    }

    /// A page that refuses its discard keeps the state it was in (it still holds its document), and
    /// the next pass, at the discard pace, tries again.
    @Test func aRefusedDiscardKeepsTheStateAndTriesAgainAtTheDiscardPace() throws {
        let settings = page("settings")
        settings.refusesDiscard = true
        lifecycle.hide("a", page: Target(page: settings))
        try fireDuePass()
        #expect(near(lifecycle.nextPassAt, .seconds(300)))
        try fireDuePass()
        #expect(log.lines == ["refuse settings"])
        #expect(lifecycle.state(of: "a") == .hidden, "a refused discard reads as discarded")
        #expect(near(lifecycle.nextPassAt, .seconds(305)), "nothing looks at the refused page again")
        settings.refusesDiscard = false
        try fireDuePass()
        #expect(log.lines == ["refuse settings", "discard settings"])
        #expect(lifecycle.state(of: "a") == .discarded)
        #expect(lifecycle.nextPassAt == nil)
    }

    @Test func anOlderHiddenPageFreezesOnceItIsNoLongerRecentlyVisible() throws {
        let history = page("history"), cloud = page("cloud")
        lifecycle.hide("h", page: Target(page: history))
        rig.advance(to: .seconds(5))
        lifecycle.hide("c", page: Target(page: cloud))
        // The earlier page lost mostRecentlyUsed now; it may freeze at 10 s.
        #expect(lifecycle.nextPassAt == .seconds(10))
        try fireDuePass()
        #expect(lifecycle.state(of: "h") == .frozen)
        #expect(lifecycle.state(of: "c") == .hidden)
        #expect(log.lines == ["freeze history"])
    }

    /// A page that refuses the freeze (it shows, or its engine did not freeze it) stays hidden: a
    /// later show does not thaw a page that never froze.
    @Test func aPageThatRefusesTheFreezeStaysHidden() throws {
        let history = page("history"), cloud = page("cloud")
        history.refusesFreeze = true
        lifecycle.hide("h", page: Target(page: history))
        rig.advance(to: .seconds(5))
        lifecycle.hide("c", page: Target(page: cloud))
        try fireDuePass()
        #expect(lifecycle.state(of: "h") == .hidden)
        lifecycle.show("h", page: Target(page: history))
        #expect(log.lines == ["freeze history"])
    }

    /// A refused freeze arms its own retry one recently visible window later: the plan's deadline
    /// for a page it decided to freeze is only the discard, so without one the page would stay
    /// hidden and running until then.
    @Test func aRefusedFreezeIsAskedAgainOneWindowLater() throws {
        let history = page("history"), cloud = page("cloud")
        history.refusesFreeze = true
        lifecycle.hide("h", page: Target(page: history))
        rig.advance(to: .seconds(5))
        lifecycle.hide("c", page: Target(page: cloud))
        try fireDuePass()
        #expect(lifecycle.state(of: "h") == .hidden)
        #expect(near(lifecycle.nextPassAt, .seconds(20)))
        history.refusesFreeze = false
        try fireDuePass()
        #expect(lifecycle.state(of: "h") == .frozen)
        #expect(log.lines == ["freeze history", "freeze history"])
    }

    @Test func showOfARunningPageDoesNotThaw() {
        let settings = page("settings")
        lifecycle.hide("a", page: Target(page: settings))
        lifecycle.show("a", page: Target(page: settings))
        #expect(log.lines.isEmpty)
        #expect(lifecycle.state(of: "a") == .active)
    }

    @Test func aFrozenPageThawsInsideItsShow() throws {
        let history = page("history"), cloud = page("cloud")
        lifecycle.hide("h", page: Target(page: history))
        rig.advance(to: .seconds(5))
        lifecycle.hide("c", page: Target(page: cloud))
        try fireDuePass()
        #expect(lifecycle.state(of: "h") == .frozen)
        lifecycle.show("h", page: Target(page: history))
        #expect(log.lines == ["freeze history", "thaw history"])
        #expect(lifecycle.state(of: "h") == .active)
    }

    @Test func aDiscardedPageThawsWhenShown() throws {
        let settings = page("settings")
        lifecycle.hide("a", page: Target(page: settings))
        try fireDuePass()
        try fireDuePass()
        #expect(lifecycle.state(of: "a") == .discarded)
        lifecycle.show("a", page: Target(page: settings))
        #expect(log.lines == ["discard settings", "thaw settings"])
    }

    @Test func aFreezeBlockingReasonKeepsThePageRunning() throws {
        let history = page("history"), cloud = page("cloud")
        history.reasons = [.audible]
        lifecycle.hide("h", page: Target(page: history))
        rig.advance(to: .seconds(5))
        lifecycle.hide("c", page: Target(page: cloud))
        try fireDuePass()
        #expect(lifecycle.state(of: "h") == .hidden)
        #expect(log.lines.isEmpty)
    }

    /// `.loading` is not time-bound: the planner arms nothing for it. The load's end is an event
    /// (``PageLifecycle/pageReasonsDidChange(_:)``) that arms a pass, so a page that hid before its
    /// load ended freezes once it ends, without another show or hide.
    @Test func aPageHiddenWhileLoadingFreezesWhenItsLoadEndsWithNoOtherEvent() throws {
        let history = page("history"), cloud = page("cloud")
        history.reasons = [.loading]
        lifecycle.hide("h", page: Target(page: history))
        #expect(history.lifecycle === lifecycle, "the page reports its reason changes")
        rig.advance(to: .seconds(5))
        lifecycle.hide("c", page: Target(page: cloud))
        try fireDuePass()
        #expect(lifecycle.state(of: "h") == .hidden)
        // The only wake left is the other page's discard: nothing would ever look at the loading page again.
        #expect(near(lifecycle.nextPassAt, .seconds(305)))
        rig.advance(to: .seconds(20))
        history.reasons = []
        history.lifecycle?.pageReasonsDidChange(history)
        #expect(lifecycle.nextPassAt == .seconds(20))
        try fireDuePass()
        #expect(lifecycle.state(of: "h") == .frozen)
        #expect(log.lines == ["freeze history"])
    }

    @Test func aReasonChangeOfAShownOrUnknownPageArmsNothing() {
        let shown = page("shown"), stranger = page("stranger")
        lifecycle.show("s", page: Target(page: shown))
        lifecycle.pageReasonsDidChange(shown)
        lifecycle.pageReasonsDidChange(stranger)
        #expect(lifecycle.nextPassAt == nil)
        #expect(rig.queue.count == 0)
    }

    @Test func anOwnerReasonThawsAFrozenPageAtOnceAndDroppingItArmsAPass() throws {
        let history = page("history"), cloud = page("cloud")
        lifecycle.hide("h", page: Target(page: history))
        rig.advance(to: .seconds(5))
        lifecycle.hide("c", page: Target(page: cloud))
        try fireDuePass()
        lifecycle.setKeepReasons([.audible], for: "h")
        #expect(lifecycle.state(of: "h") == .hidden)
        #expect(log.lines == ["freeze history", "thaw history"])
        rig.advance(to: .seconds(20))
        lifecycle.setKeepReasons([], for: "h")
        #expect(lifecycle.nextPassAt == .seconds(20))
        try fireDuePass()
        #expect(lifecycle.state(of: "h") == .frozen)
    }

    @Test func eventsTouchOnlyTheChangedPageAndAPassReadsOnlyHiddenPages() throws {
        let shown = (0..<100).map { page("p\($0)") }
        for (index, fake) in shown.enumerated() { lifecycle.show("k\(index)", page: Target(page: fake)) }
        let hiding = page("hiding")
        lifecycle.show("h", page: Target(page: hiding))
        lifecycle.hide("h", page: Target(page: hiding))
        #expect(shown.allSatisfy { $0.reasonReads == 0 })
        try fireDuePass()
        #expect(shown.allSatisfy { $0.reasonReads == 0 })
        #expect(hiding.reasonReads == 1)
    }

    @Test func criticalPressureLooksAgainAtOnceAndDiscardsSooner() throws {
        let history = page("history"), cloud = page("cloud")
        lifecycle.hide("h", page: Target(page: history))
        rig.advance(to: .seconds(5))
        lifecycle.hide("c", page: Target(page: cloud))
        try fireDuePass()
        rig.advance(to: .seconds(30))
        lifecycle.setConditions(.init(pressure: .critical))
        #expect(lifecycle.nextPassAt == .seconds(30))
        try fireDuePass()
        // Chrome's urgent pace: one discard per pass, the longest hidden first, the next 5 s later.
        #expect(lifecycle.state(of: "h") == .discarded)
        #expect(lifecycle.state(of: "c") == .hidden)
        #expect(near(lifecycle.nextPassAt, .seconds(35)))
        try fireDuePass()
        #expect(lifecycle.state(of: "c") == .discarded)
        #expect(log.lines == ["freeze history", "discard history", "discard cloud"])
    }

    /// `browser.hibernation` off reaches the planner as ``PageLifecyclePlanner/KeepReason/hibernationOff``:
    /// a hidden page is never discarded, and the setting's change arms a pass.
    @Test func withHibernationOffNoPageIsDiscardedAndTheChangeArmsAPass() throws {
        let settings = page("settings")
        var off = PageLifecyclePlanner.Conditions()
        off.setting.mode = .off
        lifecycle.setConditions(off)
        lifecycle.hide("a", page: Target(page: settings))
        try fireDuePass()
        #expect(lifecycle.nextPassAt == nil, "nothing to look at again while hibernation is off")
        rig.advance(to: .seconds(3_600))
        #expect(lifecycle.state(of: "a") == .hidden)
        lifecycle.setConditions(.init())
        #expect(lifecycle.nextPassAt == .seconds(3_600))
        try fireDuePass()
        #expect(lifecycle.state(of: "a") == .discarded)
    }

    @Test func tabEventsResolveThePageAndIgnoreTabsWithNone() throws {
        let settings = page("settings")
        var lookups: [String] = []
        lifecycle.pageOfTab = { key in
            lookups.append(key)
            return key == "page-tab" ? Target(page: settings) : nil
        }
        lifecycle.tabDidHide("terminal-tab")
        lifecycle.tabDidShow("terminal-tab")
        #expect(lifecycle.pageCount == 0)
        #expect(lifecycle.nextPassAt == nil)
        lifecycle.tabDidHide("page-tab")
        #expect(lifecycle.state(of: "page-tab") == .hidden)
        try fireDuePass()
        try fireDuePass()
        lifecycle.tabDidShow("page-tab")
        #expect(lifecycle.state(of: "page-tab") == .active)
        #expect(log.lines == ["discard settings", "thaw settings"])
        #expect(lookups == ["terminal-tab", "terminal-tab", "page-tab", "page-tab"])
    }

    @Test func removeAndForgetDropThePage() {
        let settings = page("settings"), history = page("history")
        lifecycle.hide("a", page: Target(page: settings))
        lifecycle.hide("b", page: Target(page: history))
        lifecycle.remove("a")
        lifecycle.forget(history)
        #expect(lifecycle.state(of: "a") == nil)
        #expect(lifecycle.state(of: "b") == nil)
        #expect(lifecycle.pageCount == 0)
    }

    @Test func aNewViewForTheSameTabStartsHiddenAndRunning() throws {
        let old = page("old"), new = page("new")
        lifecycle.hide("a", page: Target(page: old))
        try fireDuePass()
        try fireDuePass()
        #expect(lifecycle.state(of: "a") == .discarded)
        // The tab's view was made again (a restore) and hidden before it showed: no thaw of the old one.
        lifecycle.hide("a", page: Target(page: new))
        #expect(lifecycle.state(of: "a") == .hidden)
        #expect(log.lines == ["discard old"])
        lifecycle.forget(old)
        #expect(lifecycle.state(of: "a") == .hidden)
    }

    /// A real page: `.loading` follows its load state (not a first paint, which a hidden page never
    /// makes), its load's end arms a pass, and WebUIHost's close forgets it.
    @Test func aPageWebViewIsLoadingUntilItsLoadEndsAndWebUIHostCloseForgetsIt() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("page-lifecycle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("<!doctype html><title>Page</title>".utf8).write(to: root.appendingPathComponent("index.html"))
        let host = WebUIHost(chromium: nil, openPanel: nil,
                             memory: QuietMemoryRegistry(),
                             deadlines: LifecycleDeadlineRig.never)
        host.lifecycle = lifecycle
        let descriptor = PageDescriptor(id: "test.page-lifecycle", resource: "page-lifecycle", processGroup: .viewer, namespaces: [])
        let view = try #require(host.open(PageOpenRequest(descriptor: descriptor, root: root, routes: [])))
        let target = PageWebViewLifecycle(view, encoder: PageSnapshotEncoder { _, done in done(nil) })
        #expect(target.lifecycleGroup == "viewer")
        #expect(target.lifecycleKeepReasons.contains(.loading))
        lifecycle.hide("tab", page: target)
        #expect(view.loadState.lifecycle === lifecycle)
        #expect(lifecycle.state(of: "tab") == .hidden)
        rig.advance(to: .seconds(2))
        view.loaded = true // the document finished (either engine's load end), while hidden
        #expect(!target.lifecycleKeepReasons.contains(.loading))
        #expect(lifecycle.nextPassAt == .seconds(2), "the load's end armed no pass")
        view.loaded = false // a new load starts
        #expect(target.lifecycleKeepReasons.contains(.loading))
        view.webView(view.webView, didFailProvisionalNavigation: nil, withError: URLError(.cancelled))
        #expect(!target.lifecycleKeepReasons.contains(.loading), "a failed load still counted as loading")
        host.close(view)
        #expect(lifecycle.state(of: "tab") == nil)
    }

    // MARK: Keep reasons

    /// A host hold (a confirmation sheet) on a frozen page thaws it at the next pass, which it arms
    /// for now; its end arms a pass, and the page freezes again with no show or hide.
    @Test func aHostHoldThawsAFrozenPageAndItsEndLetsItFreezeAgain() throws {
        let history = page("history"), cloud = page("cloud")
        lifecycle.hide("h", page: Target(page: history))
        rig.advance(to: .seconds(5))
        lifecycle.hide("c", page: Target(page: cloud))
        try fireDuePass()
        #expect(lifecycle.state(of: "h") == .frozen)
        rig.advance(to: .seconds(12))
        history.keep.begin(.confirmation)
        #expect(lifecycle.nextPassAt == .seconds(12))
        try fireDuePass()
        #expect(lifecycle.state(of: "h") == .hidden)
        #expect(log.lines == ["freeze history", "thaw history"])
        rig.advance(to: .seconds(20))
        history.keep.end(.confirmation)
        #expect(lifecycle.nextPassAt == .seconds(20))
        try fireDuePass()
        #expect(lifecycle.state(of: "h") == .frozen)
        #expect(log.lines == ["freeze history", "thaw history", "freeze history"])
    }

    /// The host's holds are counted, and the page setting or ending a reason the host holds changes
    /// nothing: page script cannot end the host's hold, and no pass is armed for it.
    @Test func hostHoldsAreCountedAndThePageCannotEndOne() throws {
        let history = page("history"), cloud = page("cloud")
        lifecycle.hide("h", page: Target(page: history))
        rig.advance(to: .seconds(5))
        lifecycle.hide("c", page: Target(page: cloud))
        try fireDuePass()
        rig.advance(to: .seconds(12))
        history.keep.begin(.fileDrop)
        #expect(lifecycle.nextPassAt == .seconds(12))
        try fireDuePass()
        let armed = lifecycle.nextPassAt
        history.keep.begin(.fileDrop)
        history.keep.end(.fileDrop)
        #expect(history.keep.current == [.fileDrop])
        history.keep.setFromPage(.fileDrop, on: true)
        history.keep.setFromPage(.fileDrop, on: false)
        #expect(history.keep.current == [.fileDrop], "page script ended the host's hold")
        #expect(lifecycle.nextPassAt == armed, "an unchanged reason armed a pass")
        history.keep.end(.fileDrop)
        #expect(history.keep.current.isEmpty)
        history.keep.end(.fileDrop) // one end too many changes nothing
        #expect(history.keep.current.isEmpty)
    }

    /// A real page: `cmux.page.keepAlive` sets only a reason page script may set, never one the host
    /// or the planner owns, cannot end the host's hold, and its reasons end with a reload and a crash.
    @Test func keepAliveAddsOnlyThePagesOwnReasonsAndThoseEndOnReloadAndCrash() async throws {
        let (host, view, root) = try openKeepAlivePage()
        defer { try? FileManager.default.removeItem(at: root) }
        defer { host.close(view) }
        let target = PageWebViewLifecycle(view, encoder: PageSnapshotEncoder { _, done in done(nil) })
        lifecycle.hide("tab", page: target)
        #expect(view.keepReasons.lifecycle === lifecycle)
        var id = 0.0
        func keepAlive(_ reason: String, _ on: Bool) async -> JSONValue {
            id += 1
            return await view.router.handle(Self.keepAliveCall(id: id, reason, on))
        }

        #expect(await keepAlive("user_edits", true)["t"]?.stringValue == "ok")
        #expect(target.lifecycleKeepReasons.contains(.userEdits))
        // Not the page's to set: the host's (what it observes itself, as Chrome's browser does), the
        // planner's, an owner's, or no reason at all.
        for reason in ["focused", "loading", "inspector", "confirmation", "popup", "file_drop", "dictation", "audible",
                       "web_rtc", "connected_device", "web_lock", "recently_visible", "most_recently_used",
                       "hibernation_off", "turn_running", "page_call", "pinned", "nonsense"] {
            let refused = await keepAlive(reason, true)
            #expect(refused["code"]?.stringValue == "cmux.protocol.invalid_params", "\(reason)")
        }
        let malformed = await view.router.handle(.object([
            "t": .string("call"), "id": .number(99), "op": .string(PageNativeOp.keepAlive),
            "params": .object(["reason": .string("draft")]),
        ]))
        #expect(malformed["code"]?.stringValue == "cmux.protocol.invalid_params")
        #expect(!target.lifecycleKeepReasons.contains(.draft))
        // The host reads a drop; the page cannot end its hold.
        view.keepReasons.begin(.fileDrop)
        #expect(await keepAlive("file_drop", false)["code"]?.stringValue == "cmux.protocol.invalid_params")
        #expect(target.lifecycleKeepReasons.contains(.fileDrop))

        // A reload: a new document commits, and the old one's reasons end; the host's hold stays.
        view.documentCommitted()
        #expect(!target.lifecycleKeepReasons.contains(.userEdits))
        #expect(target.lifecycleKeepReasons.contains(.fileDrop))
        view.keepReasons.end(.fileDrop)

        // A crash ends them too.
        #expect(await keepAlive("draft", true)["t"]?.stringValue == "ok")
        #expect(view.keepReasons.fromPage == [.draft])
        view.contentProcessTerminated()
        #expect(view.keepReasons.fromPage.isEmpty)
        #expect(!target.lifecycleKeepReasons.contains(.draft))
    }

    /// A `cmux.page.keepAlive` the old document sent, still waiting to run when a reload commits
    /// the new document, never lands on it: the new document's page client never sends its end.
    @Test func aKeepAliveTheOldDocumentSentNeverLandsOnTheNewOne() async throws {
        let (host, view, root) = try openKeepAlivePage()
        defer { try? FileManager.default.removeItem(at: root) }
        defer { host.close(view) }
        let stale = Task { await view.router.handle(Self.keepAliveCall(id: 1, "user_edits", true)) }
        // The call is registered and its work is queued, not run yet.
        for _ in 0..<100 where view.router.inFlightCalls().isEmpty { await Task.yield() }
        try #require(view.router.inFlightCalls().count == 1)
        try #require(view.keepReasons.fromPage.isEmpty, "the call ran before the reload; the race is not reproduced")
        view.documentCommitted()
        let reply = await stale.value
        #expect(reply["t"]?.stringValue == "err")
        for _ in 0..<10 { await Task.yield() } // the cancelled call's work runs now, if it still can
        #expect(view.keepReasons.fromPage.isEmpty, "the old document's reason held the new one")
        // The new document's own call still sets its reason.
        #expect(await view.router.handle(Self.keepAliveCall(id: 2, "user_edits", true))["t"]?.stringValue == "ok")
        #expect(view.keepReasons.fromPage == [.userEdits])
    }

    /// A page confirmation (DialogPageConfirmationPresenter) holds the asking page's `confirmation`
    /// reason from the sheet until its answer, found from the anchor up to its PageWebView.
    @Test func aConfirmationSheetHoldsItsPageUntilItIsAnswered() async throws {
        let (host, view, root) = try openKeepAlivePage()
        defer { try? FileManager.default.removeItem(at: root) }
        defer { host.close(view) }
        let center = CmuxDialogCenter(host: SilentDialogHost())
        let presenter = DialogPageConfirmationPresenter(center: center)
        let answer = Task { await presenter.confirm(PageConfirmation(kind: .delete, name: "notes"), anchor: view.webView) }
        for _ in 0..<100 where center.records.isEmpty { await Task.yield() }
        let sheet = try #require(center.records.first)
        #expect(view.keepReasons.current == [.confirmation])
        #expect(center.press(sheet.id, button: "confirm"))
        #expect(await answer.value)
        #expect(view.keepReasons.current.isEmpty, "the answered sheet still holds its page")
    }

    /// A drop the host takes holds `fileDrop` from the drop until its owner has read it; a drag that
    /// only passes over the page (which shows, so nothing can freeze it) holds nothing.
    @Test func aDropTheHostTakesHoldsItsPageUntilItIsRead() async throws {
        let web = PageWKWebView(frame: NSRect(x: 0, y: 0, width: 200, height: 200), configuration: .init())
        let keep = PageKeepReasons()
        web.keepReasons = keep
        let file = URL(fileURLWithPath: "/tmp/cmux-page-keep-drop.png")
        web.readDroppedFileURL = { _ in file }
        var read: CheckedContinuation<Void, Never>?
        web.fileDrop = PageFileDrop(accepts: { $0.isFileURL }, open: { _ in await withCheckedContinuation { read = $0 } })
        let drag = PageFileDropDragTests.Drag(sequence: 1)
        #expect(web.draggingEntered(drag) == .copy)
        #expect(keep.current.isEmpty, "a drag over the page held it")
        web.draggingExited(drag)
        _ = web.draggingEntered(drag)
        #expect(web.performDragOperation(drag))
        #expect(keep.current == [.fileDrop])
        for _ in 0..<100 where read == nil { await Task.yield() }
        try #require(read != nil)
        #expect(keep.current == [.fileDrop], "the hold ended before the read did")
        read?.resume()
        await web.dropRead?.value
        #expect(keep.current.isEmpty, "the read drop still holds its page")
    }

    /// Web Inspector's open and close (WebKit's UI delegate) hold `inspector` on the page once,
    /// and it stays across a reload: the inspector stays open on the view.
    @Test func webInspectorHoldsItsPageWhileOpen() throws {
        let (host, view, root) = try openKeepAlivePage()
        defer { try? FileManager.default.removeItem(at: root) }
        defer { host.close(view) }
        let delegate = try #require(view.webView.uiDelegate as? PageUIDelegate)
        delegate.webView(view.webView, didAttachLocalInspector: NSObject())
        delegate.webView(view.webView, didAttachLocalInspector: NSObject())
        #expect(view.keepReasons.current == [.inspector])
        view.documentCommitted()
        #expect(view.keepReasons.current == [.inspector])
        delegate.webView(view.webView, willCloseLocalInspector: NSObject())
        #expect(view.keepReasons.current.isEmpty)
    }

    /// The page's popup past the window's edge holds `popup` from its show to its hide, and the
    /// hide arms a pass so a hidden page may freeze again.
    @Test(.enabled("needs a screen: a popup shows only in a visible window") { await MainActor.run { NSScreen.main != nil } })
    func aPopupHoldsItsPageWhileItShows() throws {
        let (host, view, root) = try openKeepAlivePage()
        defer { try? FileManager.default.removeItem(at: root) }
        defer { host.close(view) }
        let window = NSWindow(contentRect: NSRect(x: 200, y: 300, width: 500, height: 400), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil) }
        view.frame = NSRect(x: 0, y: 0, width: 500, height: 400)
        window.contentView = view
        window.orderFrontRegardless()
        window.layoutIfNeeded()
        let other = page("other")
        lifecycle.hide("tab", page: PageWebViewLifecycle(view, encoder: PageSnapshotEncoder { _, done in done(nil) }))
        rig.advance(to: .seconds(5))
        lifecycle.hide("other", page: Target(page: other))
        try fireDuePass()
        let menu: [String: Any] = ["items": [["id": "a", "label": "a"]], "anchor": ["left": 40, "top": 40, "right": 200, "bottom": 64],
                                   "width": 160, "instant": true]
        rig.advance(to: .seconds(12))
        let shown = view.popup(PageNativeOp.popupShow, params: menu)
        try #require(shown["shown"]?.boolValue == true)
        #expect(view.keepReasons.current == [.popup])
        #expect(lifecycle.nextPassAt == .seconds(12), "the popup's show armed no pass")
        try fireDuePass()
        rig.advance(to: .seconds(20))
        _ = view.popup(PageNativeOp.popupHide, params: [:])
        #expect(view.keepReasons.current.isEmpty)
        #expect(lifecycle.nextPassAt == .seconds(20), "the popup's end armed no pass")
    }

    /// The agent pane's dictation (``PageKeepReasons/dictation(_:)``) thaws a frozen page while it
    /// runs and lets it freeze again once it stops.
    @Test func dictationThawsAFrozenPageAndItsEndLetsItFreezeAgain() throws {
        let chat = page("chat"), cloud = page("cloud")
        lifecycle.hide("h", page: Target(page: chat))
        rig.advance(to: .seconds(5))
        lifecycle.hide("c", page: Target(page: cloud))
        try fireDuePass()
        #expect(lifecycle.state(of: "h") == .frozen)
        rig.advance(to: .seconds(12))
        chat.keep.dictation(true)
        try fireDuePass()
        #expect(lifecycle.state(of: "h") == .hidden)
        rig.advance(to: .seconds(20))
        chat.keep.dictation(false)
        try fireDuePass()
        #expect(lifecycle.state(of: "h") == .frozen)
        #expect(log.lines == ["freeze chat", "thaw chat", "freeze chat"])
    }

    // MARK: Keep reason helpers

    /// A real page on a WebKit host, with the suite's lifecycle, and its root folder to remove.
    private func openKeepAlivePage() throws -> (WebUIHost, PageWebView, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("page-keep-alive-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("<!doctype html><title>Page</title>".utf8).write(to: root.appendingPathComponent("index.html"))
        let host = WebUIHost(chromium: nil, openPanel: nil,
                             memory: QuietMemoryRegistry(),
                             deadlines: LifecycleDeadlineRig.never)
        host.lifecycle = lifecycle
        let descriptor = PageDescriptor(id: "test.page-keep-alive", resource: "page-keep-alive", processGroup: .viewer, namespaces: [])
        let view = try #require(host.open(PageOpenRequest(descriptor: descriptor, root: root, routes: [])))
        return (host, view, root)
    }

    private static func keepAliveCall(id: Double, _ reason: String, _ on: Bool) -> JSONValue {
        .object([
            "t": .string("call"), "id": .number(id), "op": .string(PageNativeOp.keepAlive),
            "params": .object(["reason": .string(reason), "on": .bool(on)]),
        ])
    }
}

/// A dialog host that shows nothing: the sheet waits in its center until the test answers it.
private final class SilentDialogHost: CmuxDialogHosting {
    func show(_ dialog: CmuxDialogView, in scope: CmuxDialogScope, scopeGone: @escaping () -> Void) {}
    func hide(_ dialog: CmuxDialogView) {}
}

/// The lifecycle's deadline scheduler on a wake-up queue whose timer never touches the run loop and
/// whose uptime only the test moves, and a main-thread scheduler whose posted work runs only in a
/// hand-fired frame. PageDiscardTests shares it.
@MainActor
final class LifecycleDeadlineRig {
    let queue: MainWakeUpQueue
    let scheduler: MainDeadlineScheduler
    private let uptime: RigUptime
    /// The main-thread scheduler whose posted work runs in ``fire(movingTime:)``'s frame.
    let work: MainWorkScheduler
    private let budgetClock: RigBudgetClock
    private let keeper: FrameClient
    private var frames: Double = 0

    init() {
        let uptime = RigUptime(), budgetClock = RigBudgetClock()
        self.uptime = uptime
        self.budgetClock = budgetClock
        queue = MainWakeUpQueue(energy: EnergyPolicySource(), ledger: WakeupLedger(uptime: { 0 }), uptime: { uptime.now }) { _ in
            RigWakeUpTimer()
        }
        let work = MainWorkScheduler.testing(budget: MainFrameBudget(uptimeNanos: budgetClock.read),
                                             ledger: WakeupLedger()) { _ in RigFrameLink() }
        self.work = work
        scheduler = MainDeadlineScheduler(work: work, queue: queue)
        keeper = FrameClient(owner: "test.keeper", isAnimation: false, on: work.frames) { _ in true }
        keeper.activate()
    }

    /// Now on the scheduler's clock.
    var now: Duration { scheduler.uptime }

    /// Moves the uptime forward to `time`.
    func advance(to time: Duration) { uptime.now = max(uptime.now, time.nanosecondCount) }

    /// Runs the queue's wake (with `movingTime`, at its fire date, never earlier than now), then one
    /// frame, in which the actions it posted run.
    func fire(movingTime: Bool = true) {
        if movingTime, let date = scheduler.nextFireNanos { uptime.now = max(uptime.now, date) }
        queue.fire()
        budgetClock.now += 17_000_000
        frames += 1
        work.frameDidFire(timestamp: frames, refreshInterval: 1.0 / 60)
    }
}

/// A timer the queue arms and parks; the rig fires the queue itself. Nonisolated: the queue makes
/// timers off the main actor (the test target is main actor by default), as PageWaitersTests' does.
private nonisolated final class RigWakeUpTimer: MainWakeUpTimer {
    func arm(at date: UInt64, tolerance: UInt64, now: UInt64) {}
    func park() {}
}

@MainActor
private final class RigFrameLink: FrameLink {
    var isPaused = false
    func invalidate() {}
}

/// The rig's uptime in ns: the queue reads it from any thread, only the test's main actor moves it.
private nonisolated final class RigUptime: Sendable {
    private let value = Atomic<UInt64>(0)

    var now: UInt64 {
        get { value.load(ordering: .relaxed) }
        set { value.store(newValue, ordering: .relaxed) }
    }
}

/// The frame budget's clock (`CLOCK_UPTIME_RAW` ns), one 60 Hz frame further at each fired frame.
@MainActor
private final class RigBudgetClock {
    var now: UInt64 = 1_000_000_000
    var read: () -> UInt64 { { [self] in self.now } }
}
