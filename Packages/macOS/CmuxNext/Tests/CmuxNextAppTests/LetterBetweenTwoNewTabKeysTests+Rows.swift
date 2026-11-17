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

/// More rows of the rule that a letter is typed into the tab of the New Tab key before it, and the rows of the keys
/// with Command that act on the page (Paste, Close Tab) after a letter that waits.
///
/// Each row but the last has the scene of the first file: a whole window, no daemon, no creation answered, pages
/// that load nothing, each key a key-down event through the key router. The test reports a page's field ready, and
/// reads what the app types into a page at the one call for it (`PageInputReadiness.editor`).
///
/// The last row has the real New Tab page of the build. It asks one question: a New Tab page that the pane no
/// longer shows (a second New Tab key came), does its field report ready, and can the app type into it. It waits on
/// the clock, with a limit, and it prints the times.
///
/// Limits. A row with a Return reads the Return only where the test can: the test's own view counts each key that
/// it gets, and the test's call for a key that a hold gives on records each key. A Return that the window's key
/// hold gives directly to a web view is not read.
extension LetterBetweenTwoNewTabKeysTests {
    /// The keys that a hold gave on through the services' call for a held key, in order.
    @MainActor final class GivenOn {
        struct Key {
            let code: UInt16
            let command: Bool
            /// The tab that the pane showed when the key ran again.
            let shown: String?
        }

        /// The tab that the pane shows now.
        var shown: () -> String? = { nil }
        /// Runs before the key router gets a key again.
        var before: (NSEvent) -> Void = { _ in }
        private(set) var keys: [Key] = []

        func note(_ event: NSEvent) {
            before(event)
            keys.append(Key(code: event.keyCode, command: event.modifierFlags.contains(.command), shown: shown()))
        }
    }

    /// The services of a test. A key that a hold gives on runs through the key router, in the dispatch context of an
    /// input event, and goes to the window when the router passes it on.
    static func services(pages environment: [String: String], givenOn: GivenOn) -> AppServices {
        _ = NSApplication.shared
        return AppServices(environment: AppEnvironment.current([:]), agentPaneEnvironment: environment,
                           heldKeyReplay: { event, window, router in
                               givenOn.note(event)
                               let took = router.dispatchingSynthetic(event) { router.interceptKeyDown(event, in: window) }
                               if !took { window.sendEvent(event) }
                           })
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
        let givenOn: GivenOn
        var keys: Keys

        init(controller: WindowController, services: AppServices, pane: PaneController, window: NSWindow, old: KeyCount, givenOn: GivenOn) {
            self.controller = controller
            self.services = services
            self.pane = pane
            self.window = window
            self.router = services.keyRouter
            self.input = services.keyRouter.newTabInputCoordinator
            self.old = old
            self.givenOn = givenOn
            self.keys = Keys(router: services.keyRouter, window: window)
        }

        var strip: [String] { pane.orderedIDs.map(\.rawValue) }

        /// One New Tab key: the tab that it added to the strip in its own call.
        func newTab() throws -> String {
            let before = Set(strip)
            let key = try keys.press("t", code: 17, command: true)
            try #require(key.took, "setup: the key router passed a New Tab key on")
            let made = strip.filter { !before.contains($0) }
            try #require(made.count == 1, "setup: a New Tab key added \(made.count) tabs to the strip in its own call, want 1")
            return made[0]
        }

        /// One frame of the app, then the page of `tab` with the test's read of what the app types into it. Its
        /// field is not ready.
        func pageAfterOneFrame(of tab: String, into typed: Typed) async throws -> PageInputReadiness {
            await LetterBetweenTwoNewTabKeysTests.frame(services)
            let page = try #require(LetterBetweenTwoNewTabKeysTests.page(of: tab, in: pane, into: typed),
                                    "setup: a new tab has no page with a field after one frame of the app")
            try #require(!page.isReady, "setup: the field of a new tab's page is ready after one frame, with no report")
            return page
        }

        /// One key with no Command that the window's key hold takes.
        func held(_ characters: String, code: UInt16) throws {
            let key = try keys.press(characters, code: code, command: false)
            try #require(key.took && input.log.last?.hasPrefix("hold key #") == true,
                         "setup: the window's key hold did not take the key with code \(code). The hold's log ends: \(input.log.suffix(6))")
        }

        /// The end of the key hold's log, for a message.
        var holdLog: String { input.log.suffix(8).joined(separator: " | ") }
    }

    /// Runs `body` in a window of the `large` session. `pages`: the environment that the agent pages read; the
    /// default is an inert address, so the pages load nothing.
    static func withScene(pages environment: [String: String] = [AgentPaneSource.devURLVariable: "http://127.0.0.1:9"],
                          _ body: @MainActor (Scene) async throws -> Void) async throws {
        let givenOn = GivenOn()
        let services = Self.services(pages: environment, givenOn: givenOn)
        try await LargeSessionWindowFixture.withController(.large, services: services) { _, controller in
            let tabs = services.agentTabs
            try #require(tabs.canHostChat, "setup: this build has no New Tab page")
            let pane = try #require(controller.focusedPane, "setup: the window has no focused pane")
            let window = try #require(pane.view.window, "setup: the pane's view is in no window")
            let creations = HeldCreations()
            tabs.localHost = AgentSessionRef.host(installID: "letter-between-two-new-tab-keys")
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
            let router = services.keyRouter
            let input = router.newTabInputCoordinator
            // The key hold's limit is a time on the clock: it never passes in a row.
            let began = input.now()
            input.now = { began }
            input.scheduleDeadline = { _, _ in Task {} }
            let old = KeyCount(frame: CGRect(x: 0, y: 0, width: 10, height: 10))
            pane.view.addSubview(old)
            let hasKeyboard = window.makeFirstResponder(old) && window.firstResponder === old
            givenOn.shown = { [weak pane] in pane?.currentTabKey }
            let scene = Scene(controller: controller, services: services, pane: pane, window: window, old: old, givenOn: givenOn)
            let traceBefore = router.trace
            var failure: (any Error)?
            do {
                try #require(hasKeyboard, "setup: the test's view did not get the keyboard before the first key")
                try await body(scene)
            } catch {
                failure = error
            }
            router.trace = traceBefore
            givenOn.before = { _ in }
            givenOn.shown = { nil }
            pool.makeSpare = nil
            // Each creation ends before the window closes.
            creations.release()
            await LargeSessionWindowFixture.drainMain()
            if let failure { throw failure }
        }
    }

    /// New Tab key, a letter, New Tab key, a letter, with one frame of the app after each New Tab key: each letter is
    /// typed into the tab of the New Tab key before it.
    @Test func eachLetterIsTypedIntoTheTabOfTheNewTabKeyBeforeIt() async throws {
        try await Self.withScene { scene in
            let first = Typed(), second = Typed()
            let tab1 = try scene.newTab()
            let page1 = try await scene.pageAfterOneFrame(of: tab1, into: first)
            try scene.held("a", code: 0)
            let tab2 = try scene.newTab()
            let page2 = try await scene.pageAfterOneFrame(of: tab2, into: second)
            try scene.held("b", code: 11)

            // The page of the first new tab reports its field ready.
            page1.receive(true)
            await LargeSessionWindowFixture.drainMain()
            // The page of the second new tab reports with the token of its hold, as the page does: the hold gives its
            // key on. Then its field reports ready.
            let tabs = scene.services.agentTabs
            let token = try #require(tabs.newTabPages[tabs.tabKey(tab2)]?.page.inputToken,
                                     "setup: the page of the second new tab has no token of a key hold")
            scene.input.acknowledge(token, in: scene.window)
            let gaveOn = !scene.input.isHolding(in: scene.window)
            page2.receive(true)
            await LargeSessionWindowFixture.drainMain()

            let got = (first: first.edits, second: second.edits)
            print("""
                LetterBetweenTwoNewTabKeysTests: 2 letters, 2 new tabs: the app typed \(got.first) into the first page and \
                \(got.second) into the second page; the key hold of the second new tab gave its key on at the page's report: \
                \(gaveOn); the hold's log ends: \(scene.holdLog)
                """)
            #expect(got.first == [.insert("a")],
                    "the app typed \(got.first) into the page of the first new tab, want the first letter one time. The hold's log ends: \(scene.holdLog)")
            #expect(got.second == [.insert("b")],
                    """
                    the app typed \(got.second) into the page of the second new tab, want the second letter one time. The key hold \
                    of that tab gave its key on at the page's report: \(gaveOn). The hold's log ends: \(scene.holdLog)
                    """)
            #expect(scene.old.keys == 0, "the view that had the keyboard before the first New Tab key got \(scene.old.keys) keys, want 0")
        }
    }

    /// New Tab key, a letter, Return, New Tab key: the letter is typed into the first new tab, and the Return does
    /// not run while the pane shows another tab.
    @Test func aReturnBehindALetterDoesNotRunInTheNextNewTab() async throws {
        try await Self.withScene { scene in
            let first = Typed(), second = Typed()
            let tab1 = try scene.newTab()
            let page1 = try await scene.pageAfterOneFrame(of: tab1, into: first)
            try scene.held("a", code: 0)
            try scene.held("\r", code: 36)
            let tab2 = try scene.newTab()
            let page2 = try await scene.pageAfterOneFrame(of: tab2, into: second)
            page1.receive(true)
            await LargeSessionWindowFixture.drainMain()
            page2.receive(true)
            await LargeSessionWindowFixture.drainMain()

            let got = (first: first.edits, second: second.edits)
            let returns = scene.givenOn.keys.filter { $0.code == 36 }
            let elsewhere = returns.filter { $0.shown != tab1 }
            print("""
                LetterBetweenTwoNewTabKeysTests: a letter, Return, a new tab: the app typed \(got.first) into the first page and \
                \(got.second) into the second page; \(returns.count) Return keys ran again, \(elsewhere.count) of them while the \
                pane showed another tab; the hold's log ends: \(scene.holdLog)
                """)
            #expect(got.first == [.insert("a")],
                    "the app typed \(got.first) into the page of the first new tab, want the letter one time. The hold's log ends: \(scene.holdLog)")
            #expect(got.second.isEmpty, "the app typed \(got.second) into the page of the second new tab, want nothing")
            #expect(elsewhere.isEmpty, "\(elsewhere.count) Return keys ran again while the pane showed another tab than the first new tab")
            #expect(scene.old.keys == 0, "the view that had the keyboard before the first New Tab key got \(scene.old.keys) keys, want 0")
        }
    }

    /// New Tab key, a letter, the Paste key (Cmd-V), then the page's field reports ready. The rule of today: a key with
    /// Command ends the text that waits, so the app does not type the letter after the paste ran. A change that makes
    /// the paste wait behind the letter changes this row.
    @Test func noLetterIsTypedAfterAPasteKeyRan() async throws {
        try await Self.withScene { scene in
            let typed = Typed()
            let tab = try scene.newTab()
            let page = try await scene.pageAfterOneFrame(of: tab, into: typed)
            try scene.held("a", code: 0)
            let paste = try scene.keys.press("v", code: 9, command: true)
            let queued = !scene.router.typeAhead.text.isEmpty
            await LargeSessionWindowFixture.drainMain()
            page.receive(true)
            await LargeSessionWindowFixture.drainMain()

            let got = typed.edits
            print("""
                LetterBetweenTwoNewTabKeysTests: a letter, then Cmd-V: the key router took the paste key: \(paste.took); a letter \
                was in its queue after the key's call: \(queued); the app typed \(got) into the page after the page's report; the \
                test's view got \(scene.old.keys) keys; the hold's log ends: \(scene.holdLog)
                """)
            #expect(got.isEmpty, "the app typed \(got) into the page after the paste key ran: the paste then stands before the letter")
            #expect(scene.old.keys == 0, "the view that had the keyboard before the New Tab key got \(scene.old.keys) keys, want 0")
        }
    }

    /// New Tab key, a letter, the Close Tab key (Cmd-W): the letter goes with the key. No page gets it, the view that
    /// had the keyboard before the New Tab key does not get it, and no queue keeps it. The row prints if the tab
    /// closed and does not assert it: the window has no daemon that answers a close.
    @Test func noLetterIsTypedAfterACloseTabKeyRan() async throws {
        try await Self.withScene { scene in
            let typed = Typed()
            let tab = try scene.newTab()
            let page = try await scene.pageAfterOneFrame(of: tab, into: typed)
            try scene.held("a", code: 0)
            let close = try scene.keys.press("w", code: 13, command: true)
            await LargeSessionWindowFixture.drainMain()
            await Self.frame(scene.services)
            await LargeSessionWindowFixture.drainMain()
            // A late report of the closed page.
            page.receive(true)
            await LargeSessionWindowFixture.drainMain()

            let got = typed.edits, open = scene.strip.contains(tab), queued = !scene.router.typeAhead.text.isEmpty
            print("""
                LetterBetweenTwoNewTabKeysTests: a letter, then Cmd-W: the key router took the close key: \(close.took); the new \
                tab is in the strip: \(open); the app typed \(got) into its page; a letter is in the key router's queue: \
                \(queued); the test's view got \(scene.old.keys) keys; the hold's log ends: \(scene.holdLog)
                """)
            #expect(got.isEmpty, "the app typed \(got) into the page after the Close Tab key ran, want nothing")
            #expect(!queued, "a letter waits in the key router's queue after the Close Tab key ran")
            #expect(scene.old.keys == 0, "the view that had the keyboard before the New Tab key got \(scene.old.keys) keys, want 0")
        }
    }

    /// The real New Tab page. New Tab key, one frame, New Tab key: the pane then shows the page of the second new
    /// tab. The field of the first page, which the pane no longer shows, reports ready, and the app can type into it.
    ///
    /// The two pages report in the same window of the same test process, so the page that the pane shows is the
    /// control: when no page reports, the row gives no verdict (a `setup` stop). The limit of the wait is 20 s; the
    /// app keeps text for a page that is not ready for 2 s, and the printed times say on which side each report was.
    @Test func aNewTabPageThatThePaneNoLongerShowsReportsItsField() async throws {
        try #require(AgentPaneView.bundledPage != nil, "setup: this build has no bundled page; the row needs the real New Tab page")
        try await Self.withScene(pages: [:]) { scene in
            // On a machine with a screen the window is on it, as a person's window is.
            if !NSScreen.screens.isEmpty { scene.window.orderFrontRegardless() }
            let tab1 = try scene.newTab()
            await Self.frame(scene.services)
            let page1 = try #require(scene.pane.existingContent(for: tab1)?.inputReadiness,
                                     "setup: the first new tab has no page with a field after one frame of the app")
            try #require(!page1.isReady, "setup: the field of the first page is ready after one frame; the row needs a page that is not ready at the second New Tab key")
            let tab2 = try scene.newTab()
            let start = ContinuousClock.now
            await Self.frame(scene.services)
            await LargeSessionWindowFixture.drainMain()
            let page2 = try #require(scene.pane.existingContent(for: tab2)?.inputReadiness,
                                     "setup: the second new tab has no page with a field after one frame of the app")
            try #require(scene.pane.currentTabKey == tab2 && page2 !== page1,
                         "setup: the pane does not show the page of the second new tab one frame after its key")

            // The first report of each page, from the second New Tab key.
            let limit = Duration.seconds(20)
            var hidden: Duration?, shown: Duration?
            while ContinuousClock.now - start < limit, hidden == nil || shown == nil {
                if hidden == nil, page1.isReady { hidden = ContinuousClock.now - start }
                if shown == nil, page2.isReady { shown = ContinuousClock.now - start }
                try await Task.sleep(for: .milliseconds(10))
            }
            func words(_ time: Duration?) -> String { time.map { "after \(Int($0 / .milliseconds(1))) ms" } ?? "never in 20 s" }
            let view1 = scene.services.agentTabs.existingView(tab1)
            let place = "the first page's view is in a window: \(view1?.window != nil), hidden: \(view1?.isHiddenOrHasHiddenAncestor ?? true)"
            let process = "window on screen: \(scene.window.isVisible), key window: \(scene.window.isKeyWindow), app active: \(NSApp.isActive)"

            // The app types into the first page, by its own call, and the test reads the field of the page.
            var landed = false, text: String?
            if hidden != nil {
                landed = await page1.insert("x", expectedEpoch: page1.focusEpoch)
                if let view1 {
                    let read = "const el = document.activeElement; return el ? String(el.value !== undefined ? el.value : el.textContent) : null;"
                    text = (try? await view1.callPageScript(read)).flatMap { $0 as? String }
                }
            }
            print("""
                LetterBetweenTwoNewTabKeysTests: the real New Tab page: the field of the page that the pane no longer shows \
                reported ready \(words(hidden)) from the second New Tab key; the field of the page that the pane shows reported \
                \(words(shown)); the app keeps text for a page for 2 s. The app's call typed into the first page: \(landed); its \
                field has the text: \(text ?? "not read"). \(place); \(process)
                """)
            if hidden == nil {
                try #require(shown != nil, "setup: no New Tab page reported its field ready in 20 s in this test process (\(process)): the row gives no verdict")
            }
            #expect(hidden != nil,
                    """
                    the field of the New Tab page that the pane no longer shows did not report ready in 20 s; the field of the \
                    page that the pane shows reported \(words(shown)). \(place); \(process)
                    """)
            if hidden != nil {
                #expect(landed && text?.contains("x") == true,
                        """
                        the app did not type into the page that the pane no longer shows (its call returned \(landed), the field \
                        has the text: \(text ?? "not read")). \(place); \(process)
                        """)
            }
        }
    }
}
