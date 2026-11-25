import AppKit
import CmuxNextActions
import CmuxNextAgentPane
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextFocus
import CmuxNextFocusUI
@testable import CmuxNextPages
import CmuxNextTestSupport
import Foundation
import Testing

/// A letter that a person types in the FIRST new tab while the key hold of a SECOND New Tab key is still open.
///
/// A window has one New Tab key hold (`NewTabInputCoordinator`). The hold of a New Tab key takes each letter and
/// each Delete of its window while its pane shows a New Tab page: the page of any tab, not only the page of the
/// hold's own tab. The case: New Tab key, the page of the first new tab reports and has the keyboard, New Tab key,
/// and the person goes back to the first new tab before the page of the second new tab reported. Without a rule
/// for that tab, a letter that the person types there goes into the second tab's hold. It comes late (at the report
/// of the second page), or, when the second page does not report in the hold's limit of 2 s, the hold ends with no
/// field ready and drops the letter: the view that has the keyboard then is the view that had it at the second New
/// Tab key (`NewTabHoldKeyboard`), and a key for that view is not given on.
///
/// The hold's rule for that tab (`Entry.owns`): after the hold's page showed, the tab that the pane showed before
/// the key is not the hold's, also when it is a New Tab page. A key there ends the hold, and the key router passes
/// the key on at once. The rule names that one tab: a third New Tab tab of the pane is in no row here.
///
/// The rule of these rows: a letter that a person types in a new tab whose field is ready goes to that tab. It does
/// not wait for another tab's page, and it is not lost.
///
/// 10 rows. Rows 6, 7 and 8 (a letter in the second new tab, and its key hold ends with no report of its page) are
/// in `NewTabHoldInTheFirstNewTabTests+UnreadyEnd.swift`, rows 9 and 10 (the tab of the key) in `+TabOfTheKey.swift`.
/// - Row 1: the letter is not kept by the second tab's hold.
/// - Row 2: the letter is not dropped when the second tab's hold ends at its limit.
/// - Row 3, what must stay: a letter that the person types in the SECOND new tab before its page reported waits
///   for that page and is typed into it.
/// - Row 4: a Delete in the first new tab is not kept by the second tab's hold.
/// - Row 5: a letter in a terminal tab (a tab that the pane had before the 2 keys, and that is no New Tab page) is
///   not kept by the second tab's hold, is typed into no page, and is not dropped at the hold's limit.
///
/// The rows do not say how many page views the 2 new tabs have. In an app that gives each new tab a page view of
/// its own, the 2 tabs have 2 pages. In an app where a new tab takes the page view of a New Tab tab that the person
/// did not touch, the 2 tabs have one page, which the pane's shown tab has. So a row reads the page of a tab when
/// it needs it, and the read of what the app types says which tab that page's view had at the edit. A page that
/// took a tab's context again and whose field is not ready is reported ready by the row, as the page reports.
///
/// A whole window of the `large` session with no daemon. No creation is answered before the checks end. Each key is
/// a key-down event through the app's key router (`KeyRouter.interceptKeyDown`), as the app gets a key. No page
/// loads: the row reports a page ready by the calls that the page's own messages make
/// (`NewTabInputCoordinator.acknowledge` with the token of the page's hold, `PageInputReadiness.receive`), and it
/// reads what the app types into a page at the one call by which the app types text into a page
/// (`PageInputReadiness.editor`). A frame is the app's own: the row waits for one by an event (a probe in the
/// presentation scheduler's queue). The hold's clock is the row's own (`now`), and the row runs the hold's deadline
/// itself (`scheduleDeadline`): no row sleeps, polls or reads the clock.
///
/// Limits. A key that the key router passes on goes to the view that has the keyboard, by AppKit: the rows do not
/// send it on, and they do not read the text of a field in a real page. Row 2 reads the loss from the hold's own
/// log (`dropped N keys`), as `NewTabHoldCloseKeyTests` does. Before the letter each row makes sure that the web
/// view of the first page has the keyboard, as it has after a click in the page: when the app did not give it the
/// keyboard, the row does, and the row's print says which of the 2 it was.
@MainActor @Suite(.serialized, .closesItsWindows, .timeLimit(.minutes(5)))
struct NewTabHoldInTheFirstNewTabTests {
    /// The creations of the test: each waits here, so none is answered before `release()`.
    @MainActor final class HeldCreations {
        private var waiting: [CheckedContinuation<Void, Never>] = []
        private var released = false

        func wait() async {
            if released { return }
            await withCheckedContinuation { waiting.append($0) }
        }

        func release() {
            released = true
            for one in waiting { one.resume() }
            waiting = []
        }
    }

    /// What the app typed into a page, each edit with the tab that the page's view had at that edit.
    @MainActor final class Typed {
        var edits: [(tab: String?, edit: PageInputReadiness.Edit)] = []

        /// The edits that the app made in a page while `tab` had that page's view.
        func into(_ tab: String) -> [PageInputReadiness.Edit] { edits.filter { $0.tab == tab }.map { $0.edit } }
    }

    /// The deadlines that the key hold asked for, in order: the row runs one itself.
    @MainActor final class Deadlines {
        var fires: [@MainActor @Sendable () -> Void] = []
    }

    /// The view that has the keyboard before the first key: it counts each key that it gets.
    final class KeyCount: NSView {
        var keys = 0
        override var acceptsFirstResponder: Bool { true }
        override func keyDown(with event: NSEvent) { keys += 1 }
    }

    /// The keys of the test. Each key event has a time of its own: the key router tells two key events apart by it.
    @MainActor struct Keys {
        let router: KeyRouter
        let window: NSWindow
        private var stamp = ProcessInfo.processInfo.systemUptime

        init(router: KeyRouter, window: NSWindow) {
            self.router = router
            self.window = window
        }

        /// One key-down through the key router: the event, and if the router took the key.
        mutating func press(_ characters: String, code: UInt16, command: Bool) throws -> (event: NSEvent, took: Bool) {
            stamp += 0.03
            let made = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: command ? [.command] : [], timestamp: stamp,
                                        windowNumber: window.windowNumber, context: nil, characters: characters,
                                        charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)
            let event = try #require(made, "setup: no key event could be made")
            let router = self.router, window = self.window
            return (event, router.dispatchingSynthetic(event) { router.interceptKeyDown(event, in: window) })
        }
    }

    /// Stands in the presentation scheduler's queue: its show is the event that a frame's drain ran. Its content is
    /// alive, so it spends nothing of the frame's budget, and it has no focus, so the focused pane shows before it.
    @MainActor final class FrameProbe: PresentablePane {
        var onShow: () -> Void = {}
        var selectedContentIsAlive: Bool { true }
        var isFocusedInWorkspace: Bool { false }
        func showSelected() { onShow() }
        func showWhileWaiting() {}
    }

    /// Returns when the app's next frame showed what waited for it.
    static func frame(_ services: AppServices) async {
        let probe = FrameProbe()
        await withCheckedContinuation { (shown: CheckedContinuation<Void, Never>) in
            probe.onShow = { shown.resume() }
            services.presentation.setNeedsShowSelected(probe)
        }
    }

    /// The page of the tab `key`, with the test's read of what the app types into it: nil when the tab has no page
    /// with a field.
    static func page(of key: String, in pane: PaneController, into typed: Typed) -> PageInputReadiness? {
        guard let page = pane.existingContent(for: key)?.inputReadiness else { return nil }
        page.editor = { [weak pane, weak page] edit, _ in
            // The tab that has this page's view now: a page view can go from one tab to another.
            let strip = pane?.orderedIDs.map(\.rawValue) ?? []
            let tab = strip.first { one in page != nil && pane?.existingContent(for: one)?.inputReadiness === page }
            typed.edits.append((tab: tab, edit: edit))
            return true
        }
        return page
    }

    /// 2 new tabs of a row: the page of the first one reported, the hold of the second one is open.
    @MainActor struct Two {
        let tab1: String
        let tab2: String
        /// The 2 new tabs had one page view at the frame of the second key: the second tab took the first tab's.
        let onePage: Bool
        /// At the report of the first page, the app gave that page's web view the keyboard, with no act of the row.
        let keyboardByTheApp: Bool
    }

    /// The first new tab shown again, with a page whose field is ready.
    @MainActor struct Back {
        let page: PageInputReadiness
        /// The tab switch gave the page's web view the keyboard, with no act of the row.
        let keyboardByTheSwitch: Bool
        /// The page's field was not ready after the tab switch, and the row reported it ready as the page does.
        let reportedAgain: Bool
    }

    /// The window of a row, and what the row presses and reads.
    @MainActor final class Scene {
        let controller: WindowController
        let services: AppServices
        let pane: PaneController
        let window: NSWindow
        let router: KeyRouter
        let input: NewTabInputCoordinator
        /// The view that has the keyboard before the first key.
        let old: KeyCount
        /// The time on the key hold's clock, which stands still until `passTheLimit()`.
        let began: ContinuousClock.Instant
        let deadlines: Deadlines
        var keys: Keys

        init(controller: WindowController, services: AppServices, pane: PaneController, window: NSWindow, old: KeyCount,
             began: ContinuousClock.Instant, deadlines: Deadlines) {
            self.controller = controller
            self.services = services
            self.pane = pane
            self.window = window
            self.router = services.keyRouter
            self.input = services.keyRouter.newTabInputCoordinator
            self.old = old
            self.began = began
            self.deadlines = deadlines
            self.keys = Keys(router: services.keyRouter, window: window)
        }

        var strip: [String] { pane.orderedIDs.map(\.rawValue) }

        /// The end of the key hold's log, for a message.
        var holdLog: String { input.log.suffix(8).joined(separator: " | ") }

        /// What has the keyboard now, in words.
        func keyboard(_ two: Two?) -> String {
            let responder = window.firstResponder
            if responder === old { return "the test's view" }
            let tabs = services.agentTabs
            if let two, let view = tabs.existingView(two.tab1), responder === view.webView { return "the web view of the first new tab's page" }
            if let two, let view = tabs.existingView(two.tab2), responder === view.webView { return "the web view of the second new tab's page" }
            return responder.map { String(describing: type(of: $0)) } ?? "nothing"
        }

        /// The page of the tab `tab` now, with the test's read of what the app types into it.
        func page(of tab: String, into typed: Typed) -> PageInputReadiness? {
            NewTabHoldInTheFirstNewTabTests.page(of: tab, in: pane, into: typed)
        }

        /// One New Tab key: the tab that it added to the strip in its own call.
        func newTab() throws -> String {
            let before = Set(strip)
            let key = try keys.press("t", code: 17, command: true)
            try #require(key.took, "setup: the key router passed a New Tab key on (the keyboard: \(keyboard(nil)))")
            let made = strip.filter { !before.contains($0) }
            try #require(made.count == 1, "setup: a New Tab key added \(made.count) tabs to the strip in its own call, want 1")
            return made[0]
        }

        /// The token of the key hold that the tab `tab` has in its page's context.
        func token(of tab: String) -> String? {
            let tabs = services.agentTabs
            return tabs.newTabPages[tabs.tabKey(tab)]?.page.inputToken
        }

        /// New Tab key; the page of the first new tab reports with the token of its key hold, as the page does, and
        /// its field reports ready; that page's web view has the keyboard; New Tab key. The second new tab has a
        /// page (its own, or the page that the first new tab had), no page reports for it, and its key hold is open.
        func twoNewTabs(_ typed: Typed) async throws -> Two {
            let tabs = services.agentTabs
            let tab1 = try newTab()
            await NewTabHoldInTheFirstNewTabTests.frame(services)
            let page1 = try #require(self.page(of: tab1, into: typed), "setup: the first new tab has no page with a field after one frame of the app")
            try #require(!page1.isReady, "setup: the field of the first new tab's page is ready after one frame, with no report")
            let token = try #require(self.token(of: tab1), "setup: the page of the first new tab has no token of a key hold")
            input.acknowledge(token, in: window)
            page1.receive(true)
            await LargeSessionWindowFixture.drainMain()
            try #require(!input.isHolding(in: window) && page1.isReady,
                         """
                         setup: the key hold of the first new tab did not end at its page's report (a hold is there: \
                         \(input.isHolding(in: window)), the field is ready: \(page1.isReady)). The hold's log ends: \(holdLog)
                         """)
            let view1 = try #require(tabs.existingView(tab1), "setup: the first new tab has no page view")
            // The view that has the keyboard at the second New Tab key: the first page's web view, as in the app
            // after the page's report or after a click in the page.
            let byTheApp = window.firstResponder === view1.webView
            if !byTheApp {
                try #require(window.makeFirstResponder(view1.webView) && window.firstResponder === view1.webView,
                             "setup: the web view of the first page did not take the keyboard before the second New Tab key")
            }
            let tab2 = try newTab()
            await NewTabHoldInTheFirstNewTabTests.frame(services)
            let page2 = try #require(self.page(of: tab2, into: typed), "setup: the second new tab has no page with a field after one frame of the app")
            try #require(pane.currentTabKey == tab2, "setup: the pane does not show the second new tab after one frame of the app")
            try #require(input.isHolding(in: window),
                         "setup: the second New Tab key has no key hold after one frame of the app. The hold's log ends: \(holdLog)")
            return Two(tab1: tab1, tab2: tab2, onePage: page2 === page1, keyboardByTheApp: byTheApp)
        }

        /// The person goes back to the first new tab: the pane shows it with a page whose field is ready, and that
        /// page's web view has the keyboard.
        func backToTheFirstNewTab(_ two: Two, _ typed: Typed) async throws -> Back {
            let tab = try #require(pane.orderedIDs.first { $0.rawValue == two.tab1 }, "setup: the first new tab is not in the strip")
            pane.select(tab)
            await NewTabHoldInTheFirstNewTabTests.frame(services)
            await LargeSessionWindowFixture.drainMain()
            try #require(pane.currentTabKey == two.tab1, "setup: the pane does not show the first new tab, one frame after the tab switch")
            let page = try #require(self.page(of: two.tab1, into: typed), "setup: the first new tab has no page with a field, one frame after the pane showed it again")
            try #require(pane.currentContent?.inputReadiness === page, "setup: the pane's page is not the page of the first new tab")
            // A page that took this tab's context again reports as a page does: its token, and its field ready.
            let reportedAgain = !page.isReady
            if reportedAgain {
                if let token = self.token(of: two.tab1) { input.acknowledge(token, in: window) }
                page.receive(true)
                await LargeSessionWindowFixture.drainMain()
            }
            try #require(page.isReady, "setup: the field of the first new tab's page is not ready after its report")
            try #require(!router.creationInputCoordinator.isHolding(in: window),
                         "setup: the window's creation hold is there before the letter and can take it: the row proves nothing")
            let view = try #require(services.agentTabs.existingView(two.tab1), "setup: the first new tab has no page view")
            let byTheSwitch = window.firstResponder === view.webView
            if !byTheSwitch {
                try #require(window.makeFirstResponder(view.webView) && window.firstResponder === view.webView,
                             "setup: the web view of the first new tab's page did not take the keyboard after the tab switch")
            }
            return Back(page: page, keyboardByTheSwitch: byTheSwitch, reportedAgain: reportedAgain)
        }

        /// The limit of the key hold passes on the hold's clock, and the deadline of the last hold runs.
        func passTheLimit() throws {
            let fire = try #require(deadlines.fires.last, "setup: the key hold asked for no deadline")
            let began = self.began, limit = input.holdLimit
            input.now = { began + limit }
            fire()
        }

        /// The test still reads what the app types into `page`. A `setup` stop when it does not.
        func stillReads(_ page: PageInputReadiness, into typed: Typed) async throws {
            let before = typed.edits.count
            let reads = await page.insert("seam")
            try #require(reads && typed.edits.count == before + 1 && typed.edits.last?.edit == .insert("seam"),
                         "setup: the test no longer reads what the app types into the page")
        }

        /// The lines of the hold's log that say that the hold kept a key, and that it dropped keys.
        var kept: [String] { input.log.filter { $0.hasPrefix("hold key #") } }
        var dropped: [String] { input.log.filter { $0.hasPrefix("dropped") } }
    }

    /// Runs `body` in a window of the `large` session. The agent pages get an inert address, so they load nothing.
    static func withScene(_ body: @MainActor (Scene) async throws -> Void) async throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]),
                                   agentPaneEnvironment: [AgentPaneSource.devURLVariable: "http://127.0.0.1:9"],
                                   heldKeyReplay: { event, window, router in
                                       let took = router.dispatchingSynthetic(event) { router.interceptKeyDown(event, in: window) }
                                       if !took { window.sendEvent(event) }
                                   })
        try await LargeSessionWindowFixture.withController(.large, services: services) { _, controller in
            let tabs = services.agentTabs
            try #require(tabs.canHostChat, "setup: this build has no New Tab page")
            let pane = try #require(controller.focusedPane, "setup: the window has no focused pane")
            let window = try #require(pane.view.window, "setup: the pane's view is in no window")
            let creations = HeldCreations()
            tabs.localHost = AgentSessionRef.host(installID: "new-tab-hold-in-the-first-new-tab")
            tabs.holdsTabs = { _ in true }
            tabs.reachable = { _ in true }
            tabs.create = { _, _, _, _, _, _ in
                await creations.wait()
                throw CancellationError()
            }
            // No ready page in the pool: each New Tab page of a row gets its view by the frame rule.
            let pool = services.newTabSpares
            pool.dropAll()
            pool.makeSpare = { _ in nil }
            // The key hold's clock stands still, and the row keeps each deadline that a hold asks for.
            let input = services.keyRouter.newTabInputCoordinator
            let began = input.now()
            let deadlines = Deadlines()
            input.now = { began }
            input.scheduleDeadline = { _, fire in
                deadlines.fires.append(fire)
                return Task {}
            }
            let old = KeyCount(frame: CGRect(x: 0, y: 0, width: 10, height: 10))
            pane.view.addSubview(old)
            let hasKeyboard = window.makeFirstResponder(old) && window.firstResponder === old
            let scene = Scene(controller: controller, services: services, pane: pane, window: window, old: old, began: began, deadlines: deadlines)
            var failure: (any Error)?
            do {
                try #require(hasKeyboard, "setup: the test's view did not get the keyboard before the first key")
                try await body(scene)
            } catch {
                failure = error
            }
            deadlines.fires = []
            pool.makeSpare = nil
            // Each creation ends before the window closes.
            creations.release()
            await LargeSessionWindowFixture.drainMain()
            if let failure { throw failure }
        }
    }

    /// What a row presses in the first new tab, and the edit by which the app types it into a page.
    struct Pressed {
        let name: String
        let characters: String
        let code: UInt16
        let edit: PageInputReadiness.Edit
    }

    /// Rows 1 and 4. The person presses `pressed` in the first new tab, whose field is ready, while the key hold of
    /// the second New Tab key is still open. Want: it goes to the first new tab at once. Either the key router passes
    /// the key on (the view with the keyboard, the web view of that tab's page, then gets it), or the app makes its
    /// edit in the page that the first new tab has. The second tab's hold does not keep it.
    static func pressInTheFirstNewTab(_ pressed: Pressed, row: Int) async throws {
        try await withScene { scene in
            let typed = Typed()
            let two = try await scene.twoNewTabs(typed)
            let back = try await scene.backToTheFirstNewTab(two, typed)
            let holdBefore = scene.input.isHolding(in: scene.window), keyboard = scene.keyboard(two)

            let key = try scene.keys.press(pressed.characters, code: pressed.code, command: false)
            await LargeSessionWindowFixture.drainMain()
            let got = (first: typed.into(two.tab1), second: typed.into(two.tab2))
            let keeps = scene.input.isHolding(in: scene.window)
            print("""
                NewTabHoldInTheFirstNewTabTests: row \(row), \(pressed.name) in the first new tab, the second tab's hold open: \
                the key router took the key: \(key.took); the app made the edits \(got.first) in the first new tab's page and \
                \(got.second) in the second new tab's page; a key hold was there before the key: \(holdBefore), after it: \
                \(keeps); the 2 new tabs had one page view: \(two.onePage); the keyboard at the key: \(keyboard) (by the app at \
                the first page's report: \(two.keyboardByTheApp), by the tab switch: \(back.keyboardByTheSwitch)); the row \
                reported the page ready again after the tab switch: \(back.reportedAgain); the test's view got \
                \(scene.old.keys) keys; the hold's log ends: \(scene.holdLog)
                """)
            #expect(!key.took || got.first == [pressed.edit],
                    """
                    \(pressed.name) that was pressed in the first new tab, whose field is ready, did not go to that tab: the key \
                    router took the key, and the app made the edits \(got.first) in that tab's page. A key hold was there after \
                    the key: \(keeps). The hold's log ends: \(scene.holdLog)
                    """)
            #expect(got.second.isEmpty, "the app made the edits \(got.second) in the page of the second new tab, want none")
            #expect(scene.old.keys == 0, "the view that had the keyboard before the first New Tab key got \(scene.old.keys) keys, want 0")
            try await scene.stillReads(back.page, into: typed)
        }
    }

    /// Row 1. A letter in the first new tab is not kept by the second tab's hold.
    @Test func aLetterInTheFirstNewTabIsNotKeptByTheSecondTabsHold() async throws {
        try await Self.pressInTheFirstNewTab(Pressed(name: "a letter", characters: "a", code: 0, edit: .insert("a")), row: 1)
    }

    /// Row 4. A Delete in the first new tab is not kept by the second tab's hold.
    @Test func aDeleteInTheFirstNewTabIsNotKeptByTheSecondTabsHold() async throws {
        let delete = Pressed(name: "a Delete", characters: "\u{7F}", code: KeyRouter.deleteKeyCode, edit: .deleteBackward(1))
        try await Self.pressInTheFirstNewTab(delete, row: 4)
    }

    /// Row 2. The same letter, and no page reports for the second new tab: the limit of its key hold passes, and
    /// the hold's deadline runs. Want: the letter is not lost. The hold's log has no line of a dropped key.
    @Test func aLetterInTheFirstNewTabIsNotDroppedAtTheLimitOfTheSecondTabsHold() async throws {
        try await Self.withScene { scene in
            let typed = Typed()
            let two = try await scene.twoNewTabs(typed)
            let back = try await scene.backToTheFirstNewTab(two, typed)
            let atTheLetter = scene.keyboard(two)

            let key = try scene.keys.press("a", code: 0, command: false)
            await LargeSessionWindowFixture.drainMain()
            // No page reports for the second new tab. The limit passes on the hold's clock.
            let atTheLimit = scene.keyboard(two)
            let holdAtTheLimit = scene.input.isHolding(in: scene.window)
            try scene.passTheLimit()
            await LargeSessionWindowFixture.drainMain()
            let ended = !scene.input.isHolding(in: scene.window)
            let dropped = scene.dropped
            let got = (first: typed.into(two.tab1), second: typed.into(two.tab2))
            print("""
                NewTabHoldInTheFirstNewTabTests: row 2, a letter in the first new tab, then the limit of the second tab's hold: \
                the key router took the letter: \(key.took); a key hold was there at the limit: \(holdAtTheLimit); it ended at \
                its limit: \(ended); the hold's lines of dropped keys: \(dropped); the app made the edits \(got.first) in the \
                first new tab's page and \(got.second) in the second new tab's page; the 2 new tabs had one page view: \
                \(two.onePage); the keyboard at the letter: \(atTheLetter), at the limit: \(atTheLimit) (by the app at the \
                first page's report: \(two.keyboardByTheApp), by the tab switch: \(back.keyboardByTheSwitch)); the test's view \
                got \(scene.old.keys) keys; the hold's log ends: \(scene.holdLog)
                """)
            try #require(ended, "setup: the key hold was still there after the row ran its deadline. The hold's log ends: \(scene.holdLog)")
            #expect(dropped.isEmpty,
                    """
                    a letter that was typed in the first new tab, whose field is ready, was lost when the key hold of the \
                    second new tab ended at its limit: \(dropped). The key router took the letter: \(key.took). The hold's log \
                    ends: \(scene.holdLog)
                    """)
            #expect(got.second.isEmpty, "the app made the edits \(got.second) in the page of the second new tab, want none")
            #expect(scene.old.keys == 0, "the view that had the keyboard before the first New Tab key got \(scene.old.keys) keys, want 0")
            try await scene.stillReads(back.page, into: typed)
        }
    }

    /// Row 3, what must stay. The pane shows the second new tab, and no page reported for it. A letter that the
    /// person types there waits for that tab's page: at the page's report, with the token of the tab's key hold and
    /// a ready field, the app types the letter into the page that the second new tab has, one time, and nothing
    /// into a page of the first new tab.
    ///
    /// The letter comes to the page by one of 2 ways, and the row wants one of them, one time. Way 1, a page whose
    /// field was not ready before the report (the second tab has a page view of its own): the key router queues
    /// the letter and the app types it by its edit call (`PageInputReadiness.editor`). Way 2, a page whose field
    /// was ready before the letter (the second tab took the page view of the first tab, whose field reported): the
    /// hold gives the letter on as a key-down, and the key router passes it on to the page's view, whose web view
    /// has the keyboard. For way 2 the row reads the host's mark of a key on that view (`AgentPaneHostTouch`), which
    /// the hold's replay sets when it gives a key to an agent page's view; the view had no mark before the letter.
    /// Limit: the row does not read the key event that the web view gets.
    @Test func aLetterInTheSecondNewTabBeforeItsReportIsTypedIntoThatTab() async throws {
        try await Self.withScene { scene in
            let typed = Typed()
            let two = try await scene.twoNewTabs(typed)
            let page2 = try #require(scene.page(of: two.tab2, into: typed), "setup: the second new tab has no page with a field")
            let shows = scene.pane.currentTabKey == two.tab2 && scene.pane.currentContent?.inputReadiness === page2
            try #require(shows, "setup: the pane does not show the page of the second new tab after one frame of the app")
            let creationHold = scene.router.creationInputCoordinator.isHolding(in: scene.window)
            let keyboard = scene.keyboard(two)
            let view2 = try #require(scene.services.agentTabs.existingView(two.tab2), "setup: the second new tab has no page view")
            let readyBefore = page2.isReady, markBefore = view2.model.hostTouch.marked
            try #require(!markBefore, "setup: the page view of the second new tab has the host's mark before the letter (by \(view2.model.hostTouch.by ?? "none")): way 2 then proves nothing")

            let key = try scene.keys.press("b", code: 11, command: false)
            let held = key.took && scene.input.log.last?.hasPrefix("hold key #") == true
            let token = try #require(scene.token(of: two.tab2), "setup: the page of the second new tab has no token of a key hold")
            scene.input.acknowledge(token, in: scene.window)
            let gaveOn = !scene.input.isHolding(in: scene.window)
            page2.receive(true)
            await LargeSessionWindowFixture.drainMain()
            let got = (first: typed.into(two.tab1), second: typed.into(two.tab2))
            // Way 2: the hold's replay gave the letter as a key-down to the page view that the second tab still has, whose web view has the keyboard.
            let touch = view2.model.hostTouch
            let stillTheTabs = scene.services.agentTabs.existingView(two.tab2) === view2
            let asAKey = touch.marked && touch.by == "key" && stillTheTabs && scene.window.firstResponder === view2.webView
            print("""
                NewTabHoldInTheFirstNewTabTests: row 3, a letter in the second new tab before its report: the key router took \
                the letter: \(key.took) (the key hold took it: \(held); the window's creation hold was there before the \
                letter: \(creationHold)); the hold gave its key on at the page's report: \(gaveOn); the app made the edits \
                \(got.first) in the first new tab's page and \(got.second) in the second new tab's page; the 2 new tabs had \
                one page view: \(two.onePage); the field of the second tab's page was ready before the letter: \
                \(readyBefore); the page view of the second tab got the letter as a key-down (the host's mark of a key, \
                the view is still the tab's, its web view has the keyboard): \(asAKey) (the mark: \(touch.marked), by \
                \(touch.by ?? "none")); the keyboard at the letter: \(keyboard), after the report: \
                \(scene.keyboard(two)); the test's view got \(scene.old.keys) keys; the hold's log ends: \(scene.holdLog)
                """)
            let byTheEdit = got.second == [.insert("b")] && !asAKey
            let byTheKey = got.second.isEmpty && asAKey && readyBefore
            #expect(held && gaveOn, "the key hold of the second new tab did not take the letter (\(held)) or did not give it on at the page's report (\(gaveOn)). The hold's log ends: \(scene.holdLog)")
            #expect(byTheEdit || byTheKey,
                    """
                    the letter did not come to the second new tab one time: the app made the edits \(got.second) in its \
                    page (way 1 wants the letter one time and no key-down), and its page view got the letter as a key-down: \
                    \(asAKey), with a field that was ready before the letter: \(readyBefore) (way 2 wants the key-down, a \
                    ready field and no edit). The key router took the letter: \(key.took). The hold's log ends: \(scene.holdLog)
                    """)
            #expect(got.first.isEmpty, "the app made the edits \(got.first) in a page of the first new tab, want none")
            #expect(scene.old.keys == 0, "the view that had the keyboard before the first New Tab key got \(scene.old.keys) keys, want 0")
            try await scene.stillReads(page2, into: typed)
            if let page1 = scene.page(of: two.tab1, into: typed), page1 !== page2 { try await scene.stillReads(page1, into: typed) }
        }
    }

    /// Row 5. The person goes to a terminal tab (a tab that the pane had before the 2 keys; the row picks it by the
    /// store's kind and stops when it is a New Tab page) while the key hold of the second New Tab key is still open,
    /// and types a letter there. The test's view has the keyboard, in the place of that tab's own view. Want: the
    /// hold does not keep the letter, the app types it into no page, and no key is dropped when the hold's limit
    /// passes.
    @Test func aLetterInATabThatIsNoNewTabPageIsNotKeptByTheSecondTabsHold() async throws {
        try await Self.withScene { scene in
            let typed = Typed()
            let tabs = scene.services.agentTabs
            let two = try await scene.twoNewTabs(typed)
            let terminal = try #require(scene.pane.pane.tabs.first { $0.kind == .pty }?.id, "setup: the pane has no terminal tab")
            let other = try #require(scene.pane.orderedIDs.first { $0.rawValue == terminal }, "setup: the terminal tab is not in the strip")
            scene.pane.select(other)
            await NewTabHoldInTheFirstNewTabTests.frame(scene.services)
            await LargeSessionWindowFixture.drainMain()
            try #require(scene.pane.currentTabKey == other.rawValue,
                         "setup: the pane does not show the terminal tab, one frame after the tab switch (it shows \(scene.pane.currentTabKey ?? "no tab"))")
            try #require(!tabs.isNewTabPage(other.rawValue), "setup: the terminal tab is a New Tab page after the pane showed it")
            try #require(scene.window.makeFirstResponder(scene.old) && scene.window.firstResponder === scene.old,
                         "setup: the test's view did not take the keyboard after the tab switch")
            let holdBefore = scene.input.isHolding(in: scene.window), keptBefore = scene.kept.count, keysBefore = scene.old.keys

            let key = try scene.keys.press("c", code: 8, command: false)
            await LargeSessionWindowFixture.drainMain()
            let kept = scene.kept.count - keptBefore
            let holdAfter = scene.input.isHolding(in: scene.window)
            // A hold that is still there: its limit passes, and its deadline runs.
            if holdAfter {
                try scene.passTheLimit()
                await LargeSessionWindowFixture.drainMain()
            }
            let dropped = scene.dropped
            let edits = typed.edits.map { one -> String in
                let place = one.tab == two.tab1 ? "the first new tab" : one.tab == two.tab2 ? "the second new tab" : "another tab"
                return "\(one.edit) in the page of \(place)"
            }
            print("""
                NewTabHoldInTheFirstNewTabTests: row 5, a letter in a terminal tab that is no New Tab page, the second tab's hold open: \
                the key router took the letter: \(key.took); the hold kept \(kept) keys; a key hold was there before the \
                letter: \(holdBefore), after it: \(holdAfter); the hold's lines of dropped keys: \(dropped); the app's edits \
                in pages: \(edits); the test's view got \(scene.old.keys - keysBefore) keys after the tab switch; the 2 new \
                tabs had one page view: \(two.onePage); the hold's log ends: \(scene.holdLog)
                """)
            #expect(kept == 0, "the key hold of the second new tab kept \(kept) keys that were typed in a tab that is no New Tab page. The hold's log ends: \(scene.holdLog)")
            #expect(edits.isEmpty, "a letter that was typed in a tab that is no New Tab page made edits in a page: \(edits)")
            #expect(dropped.isEmpty, "a letter that was typed in a tab that is no New Tab page was lost: \(dropped). The hold's log ends: \(scene.holdLog)")
        }
    }
}
