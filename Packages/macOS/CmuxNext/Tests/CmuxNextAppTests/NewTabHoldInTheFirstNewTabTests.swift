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
/// and the person goes back to the first new tab before the page of the second new tab reported. A letter that the
/// person types there goes into the second tab's hold. It comes late (at the report of the second page), or, when
/// the second page does not report in the hold's limit of 2 s, the hold ends with no field ready and drops the
/// letter: the view that has the keyboard then is the view that had it at the second New Tab key
/// (`NewTabHoldKeyboard`), and a key for that view is not given on.
///
/// The rule of these rows: a letter that a person types in a new tab whose field is ready goes to that tab. It does
/// not wait for another tab's page, and it is not lost.
///
/// 3 rows.
/// - Row 1: the letter is not kept by the second tab's hold.
/// - Row 2: the letter is not dropped when the second tab's hold ends at its limit.
/// - Row 3, what must stay: a letter that the person types in the SECOND new tab before its page reported waits
///   for that page and is typed into it.
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

    /// What the app typed into a page.
    @MainActor final class Typed {
        var edits: [PageInputReadiness.Edit] = []
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
        page.editor = { edit, _ in
            typed.edits.append(edit)
            return true
        }
        return page
    }

    /// 2 new tabs of a row: the page of the first one reported, the page of the second one did not.
    @MainActor struct Two {
        let tab1: String
        let tab2: String
        let page1: PageInputReadiness
        let page2: PageInputReadiness
        /// The view of the first new tab's page.
        let view1: AgentPaneView
        /// At the report of the first page, the app gave that page's web view the keyboard, with no act of the row.
        let keyboardByTheApp: Bool
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
            if let two, responder === two.view1.webView { return "the first page's web view" }
            if let two, let other = services.agentTabs.existingView(two.tab2), responder === other.webView { return "the second page's web view" }
            return responder.map { String(describing: type(of: $0)) } ?? "nothing"
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

        /// One frame of the app, then the page of `tab` with the test's read of what the app types into it. Its
        /// field is not ready.
        func pageAfterOneFrame(of tab: String, into typed: Typed) async throws -> PageInputReadiness {
            await NewTabHoldInTheFirstNewTabTests.frame(services)
            let page = try #require(NewTabHoldInTheFirstNewTabTests.page(of: tab, in: pane, into: typed),
                                    "setup: a new tab has no page with a field after one frame of the app")
            try #require(!page.isReady, "setup: the field of a new tab's page is ready after one frame, with no report")
            return page
        }

        /// New Tab key; the page of the first new tab reports with the token of its key hold, as the page does, and
        /// its field reports ready; that page's web view has the keyboard; New Tab key. The page of the second new
        /// tab has its view and does not report.
        func twoNewTabs(first: Typed, second: Typed) async throws -> Two {
            let tabs = services.agentTabs
            let tab1 = try newTab()
            let page1 = try await pageAfterOneFrame(of: tab1, into: first)
            let token = try #require(tabs.newTabPages[tabs.tabKey(tab1)]?.page.inputToken,
                                     "setup: the page of the first new tab has no token of a key hold")
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
            let page2 = try await pageAfterOneFrame(of: tab2, into: second)
            try #require(input.isHolding(in: window),
                         "setup: the second New Tab key has no key hold after one frame of the app. The hold's log ends: \(holdLog)")
            return Two(tab1: tab1, tab2: tab2, page1: page1, page2: page2, view1: view1, keyboardByTheApp: byTheApp)
        }

        /// The person goes back to the first new tab: the pane shows its page again, and that page's web view has
        /// the keyboard. Returns if the tab switch gave it the keyboard, with no act of the row.
        func backToTheFirstNewTab(_ two: Two) async throws -> Bool {
            let tab = try #require(pane.orderedIDs.first { $0.rawValue == two.tab1 }, "setup: the first new tab is not in the strip")
            pane.select(tab)
            await NewTabHoldInTheFirstNewTabTests.frame(services)
            await LargeSessionWindowFixture.drainMain()
            let shows = pane.currentTabKey == two.tab1 && pane.currentContent?.inputReadiness === two.page1
            try #require(shows && two.page1.isReady,
                         """
                         setup: the row needs the page of the first new tab as the pane's page again, with a field that is \
                         ready (the pane shows that page: \(shows), the field is ready: \(two.page1.isReady))
                         """)
            try #require(!router.creationInputCoordinator.isHolding(in: window),
                         "setup: the window's creation hold is there before the letter and can take it: the row proves nothing")
            let byTheSwitch = window.firstResponder === two.view1.webView
            if !byTheSwitch {
                try #require(window.makeFirstResponder(two.view1.webView) && window.firstResponder === two.view1.webView,
                             "setup: the web view of the first page did not take the keyboard after the tab switch")
            }
            return byTheSwitch
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
            try #require(reads && typed.edits.count == before + 1 && typed.edits.last == .insert("seam"),
                         "setup: the test no longer reads what the app types into the page")
        }
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

    /// Row 1. The person types a letter in the first new tab, whose field is ready, while the key hold of the second
    /// New Tab key is still open. Want: the letter goes to the first new tab at once. Either the key router passes
    /// the key on (the view with the keyboard, the first page's web view, then gets it), or the app types the letter
    /// into the first page. The second tab's hold does not keep it.
    @Test func aLetterInTheFirstNewTabIsNotKeptByTheSecondTabsHold() async throws {
        try await Self.withScene { scene in
            let first = Typed(), second = Typed()
            let two = try await scene.twoNewTabs(first: first, second: second)
            let bySwitch = try await scene.backToTheFirstNewTab(two)
            let holdBefore = scene.input.isHolding(in: scene.window), keyboard = scene.keyboard(two)

            let key = try scene.keys.press("a", code: 0, command: false)
            await LargeSessionWindowFixture.drainMain()
            let got = (first: first.edits, second: second.edits)
            let keeps = scene.input.isHolding(in: scene.window)
            print("""
                NewTabHoldInTheFirstNewTabTests: row 1, a letter in the first new tab, the second tab's hold open: the key \
                router took the letter: \(key.took); the app typed \(got.first) into the first page and \(got.second) into the \
                second page; a key hold was there before the letter: \(holdBefore), after it: \(keeps); the keyboard at the \
                letter: \(keyboard) (by the app at the first page's report: \(two.keyboardByTheApp), by the tab switch: \
                \(bySwitch)); the test's view got \(scene.old.keys) keys; the hold's log ends: \(scene.holdLog)
                """)
            #expect(!key.took || got.first == [.insert("a")],
                    """
                    a letter that was typed in the first new tab, whose field is ready, did not go to that tab: the key router \
                    took the key, and the app typed \(got.first) into the first page. A key hold was there after the letter: \
                    \(keeps). The hold's log ends: \(scene.holdLog)
                    """)
            #expect(got.second.isEmpty, "the app typed \(got.second) into the page of the second new tab, want nothing")
            #expect(scene.old.keys == 0, "the view that had the keyboard before the first New Tab key got \(scene.old.keys) keys, want 0")
            try await scene.stillReads(two.page1, into: first)
        }
    }

    /// Row 2. The same letter, and the page of the second new tab never reports: the limit of its key hold passes,
    /// and the hold's deadline runs. Want: the letter is not lost. The hold's log has no line of a dropped key.
    @Test func aLetterInTheFirstNewTabIsNotDroppedAtTheLimitOfTheSecondTabsHold() async throws {
        try await Self.withScene { scene in
            let first = Typed(), second = Typed()
            let two = try await scene.twoNewTabs(first: first, second: second)
            let bySwitch = try await scene.backToTheFirstNewTab(two)
            let atTheLetter = scene.keyboard(two)

            let key = try scene.keys.press("a", code: 0, command: false)
            await LargeSessionWindowFixture.drainMain()
            // The page of the second new tab does not report. The limit passes on the hold's clock.
            let atTheLimit = scene.keyboard(two)
            try scene.passTheLimit()
            await LargeSessionWindowFixture.drainMain()
            let ended = !scene.input.isHolding(in: scene.window)
            let dropped = scene.input.log.filter { $0.hasPrefix("dropped") }
            let got = (first: first.edits, second: second.edits)
            print("""
                NewTabHoldInTheFirstNewTabTests: row 2, a letter in the first new tab, then the limit of the second tab's hold: \
                the key router took the letter: \(key.took); the hold ended at its limit: \(ended); the hold's lines of dropped \
                keys: \(dropped); the app typed \(got.first) into the first page and \(got.second) into the second page; the \
                keyboard at the letter: \(atTheLetter), at the limit: \(atTheLimit) (by the app at the first page's report: \
                \(two.keyboardByTheApp), by the tab switch: \(bySwitch)); the test's view got \(scene.old.keys) keys; the \
                hold's log ends: \(scene.holdLog)
                """)
            try #require(ended, "setup: the key hold was still there after the row ran its deadline. The hold's log ends: \(scene.holdLog)")
            #expect(dropped.isEmpty,
                    """
                    a letter that was typed in the first new tab, whose field is ready, was lost when the key hold of the \
                    second new tab ended at its limit: \(dropped). The key router took the letter: \(key.took). The hold's log \
                    ends: \(scene.holdLog)
                    """)
            #expect(got.second.isEmpty, "the app typed \(got.second) into the page of the second new tab, want nothing")
            #expect(scene.old.keys == 0, "the view that had the keyboard before the first New Tab key got \(scene.old.keys) keys, want 0")
            try await scene.stillReads(two.page1, into: first)
        }
    }

    /// Row 3, what must stay. The pane shows the second new tab, and its page did not report. A letter that the
    /// person types there waits for that page: at the page's report, with the token of its key hold and a ready
    /// field, the app types the letter into the second page, one time, and nothing into the first page.
    @Test func aLetterInTheSecondNewTabBeforeItsReportIsTypedIntoThatTab() async throws {
        try await Self.withScene { scene in
            let first = Typed(), second = Typed()
            let two = try await scene.twoNewTabs(first: first, second: second)
            let shows = scene.pane.currentTabKey == two.tab2 && scene.pane.currentContent?.inputReadiness === two.page2
            try #require(shows, "setup: the pane does not show the page of the second new tab after one frame of the app")
            let creationHold = scene.router.creationInputCoordinator.isHolding(in: scene.window)
            let keyboard = scene.keyboard(two)

            let key = try scene.keys.press("b", code: 11, command: false)
            let held = key.took && scene.input.log.last?.hasPrefix("hold key #") == true
            let tabs = scene.services.agentTabs
            let token = try #require(tabs.newTabPages[tabs.tabKey(two.tab2)]?.page.inputToken,
                                     "setup: the page of the second new tab has no token of a key hold")
            scene.input.acknowledge(token, in: scene.window)
            let gaveOn = !scene.input.isHolding(in: scene.window)
            two.page2.receive(true)
            await LargeSessionWindowFixture.drainMain()
            let got = (first: first.edits, second: second.edits)
            print("""
                NewTabHoldInTheFirstNewTabTests: row 3, a letter in the second new tab before its report: the key router took \
                the letter: \(key.took) (the key hold took it: \(held); the window's creation hold was there before the \
                letter: \(creationHold)); the hold gave its key on at the page's report: \(gaveOn); the app typed \(got.first) into the first page and \(got.second) into the second page; the keyboard \
                at the letter: \(keyboard), after the report: \(scene.keyboard(two)); the test's view got \(scene.old.keys) \
                keys; the hold's log ends: \(scene.holdLog)
                """)
            #expect(got.second == [.insert("b")],
                    """
                    the app typed \(got.second) into the page of the second new tab, want the letter one time. The key router \
                    took the letter: \(key.took). The hold's log ends: \(scene.holdLog)
                    """)
            #expect(got.first.isEmpty, "the app typed \(got.first) into the page of the first new tab, want nothing")
            #expect(scene.old.keys == 0, "the view that had the keyboard before the first New Tab key got \(scene.old.keys) keys, want 0")
            try await scene.stillReads(two.page1, into: first)
            try await scene.stillReads(two.page2, into: second)
        }
    }
}
