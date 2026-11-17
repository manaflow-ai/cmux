import AppKit
@testable import CmuxNextAgentPane
@testable import CmuxNextApp
import CmuxNextDaemon
@testable import CmuxNextPages
import CmuxNextTestSupport
import Foundation
import Testing

/// Each New Tab key gave its tab a page view of its own: a prewarmed one when the pool had one, else a web view made
/// and loaded for that key. A page load is far above one key gap, so in a run of keys the pool is empty after the
/// first key, and each later tab shows a page that still loads.
///
/// The rule (decision 2026-11-16): the New Tab tabs of a pane that no person used yet show ONE page view. A key adds
/// a tab to the strip and makes no page view; a tab gets a page view of its own at its first use, and that view is
/// the one on screen then. These rows hold the rule by counts, with no display:
///
/// - a run of New Tab keys makes no page view and starts no refill of the pool;
/// - after each key the pane shows the page view that it showed before the key;
/// - a touch of one such tab leaves the others with no page view of their own, and they show another, untouched view;
/// - the first touch keeps the page view on screen and makes it the tab's own (this row is green before the change);
/// - a close of such a tab keeps the page view on screen for the pane's other such tab, and gives none to the pool.
///
/// The pool's refill is the test's: it counts each start and makes no page, so the pool stays empty. The touch is the
/// page's own report of a person's first edit (`newTab.touched`). A key is the New Tab action's body, not a key event:
/// the key router is not in these rows. Frames are the app's own; a test waits for one by an event (a probe in the
/// scheduler's queue). No wait here polls and none reads a clock. (The shared setup that starts the app and finds its
/// focused pane is the base's, and waits in its own way before a test's first line.)
///
/// The key rows (the second part of the file) send each key through the app's dispatch: the key router, then the
/// window. They hold the rule of a touch: a text key for an untouched New Tab page is a person's use of the selected
/// tab in the key's own turn (the page's report of an edit comes later than the next key), and a chord is no use:
///
/// - New Tab keys and a select touch no page (green before the change);
/// - one text key is one touch in the key's turn, and so is a text key that the New Tab field's hold gives back;
/// - New Tab, New Tab, 3 text keys in one turn: the second tab owns the touched page, the first has no page of its own;
/// - New Tab, `a`, New Tab, `b` in one turn: each letter goes to the page of its own tab, and none is dropped;
/// - New Tab, text, Close Tab in one turn: the pane's other tab then shows a page that no key touched (green before).
///
/// In the key rows each page has an inert address, so a page's reports (its document's focus, its field's readiness)
/// are the test's, and no clock ends a hold. Their limit: a row reads which page view has the keyboard and which tab
/// owns it at each key. The text in a page's field is the page's memory: no row here reads it.
///
/// The engine: each page view here is a real one (`engine-of-test:` in the run's output). The package's tests have no
/// Chromium host, so that engine is WebKit: a pass here holds the rule of the host code, and is no proof of the look
/// or the times of a Chromium page.
@MainActor @Suite(.serialized, .timeLimit(.minutes(5)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"),
                  .closesItsWindows)
struct UntouchedNewTabsShowOnePageTests {
    /// Stands in the presentation scheduler's queue: its show is the event that a frame's drain ran. Its content is
    /// alive, so it spends nothing of the frame's budget, and it has no focus, so the focused pane shows before it.
    @MainActor private final class FrameProbe: PresentablePane {
        var onShow: () -> Void = {}
        var selectedContentIsAlive: Bool { true }
        var isFocusedInWorkspace: Bool { false }
        func showSelected() { onShow() }
        func showWhileWaiting() {}
    }

    /// The counts of one test, since the app's start.
    @MainActor private final class Counts {
        /// Each page view that the tab store built or adopted for a tab, by the tab's key.
        var built: [String] = []
        /// The engine of each such page view.
        var engines: [String] = []
        /// Each start of a refill of the pool.
        var refills = 0
        /// Each page view that a closed tab gave back to the pool.
        var recycles = 0
        /// The keys of the pane's tabs before the setup's key: the store's own keys, which do not change.
        var hadAtStart: [String] = []
    }

    /// Returns when the scheduler's next frame showed what waited for it.
    private static func frame(_ services: AppServices) async {
        let probe = FrameProbe()
        await withCheckedContinuation { (shown: CheckedContinuation<Void, Never>) in
            probe.onShow = { shown.resume() }
            services.presentation.setNeedsShowSelected(probe)
        }
    }

    /// The page view that the pane shows now, when its shown tab's content is one.
    private static func shownPage(_ pane: PaneController) -> AgentPaneView? {
        if case .agent(let view)? = pane.currentContent { return view }
        return nil
    }

    /// How many New Tab tabs the pane got since the app's start (`had`: its tabs' keys then).
    private static func newTabCount(_ pane: PaneController, _ services: AppServices, since had: [String]) -> Int {
        pane.stripModel.tabs.map(\.id.rawValue).filter { !had.contains($0) && services.agentTabs.isNewTabPage($0) }.count
    }

    /// The app with a pane that shows a New Tab tab, which no person used: the setup's one key and its frame. The
    /// pool is empty and its refill makes nothing. `body` gets the pane, its window and the counts. A test names its
    /// own tabs as the New Tab tabs that the pane did not have at the app's start.
    private static func withAPaneThatShowsANewTab(_ install: String,
                                                  _ body: (AppServices, NSWindow, PaneController, Counts) async throws -> Void) async throws {
        try await PasswordManagerRouteTests.withApp { services, _ in
            services.agentTabs.localHost = AgentSessionRef.host(installID: install)
            try #require(services.agentTabs.canHostChat, "this build has no New Tab page")
            let (window, pane) = try await NewTabOpenFramesTests.focusedPane(services)
            let pool = services.newTabSpares, tabs = services.agentTabs
            let counts = Counts()
            pool.dropAll()
            pool.makeSpare = { _ in
                counts.refills += 1
                return nil
            }
            // Each page view that the tab store builds or adopts tells this; the app's own listeners still hear both.
            let wiredBuilt = tabs.onPageBuilt
            let wiredRecycle = tabs.recycle
            tabs.onPageBuilt = { key in
                counts.built.append(key)
                counts.engines.append(tabs.existingView(key)?.engineName ?? "no view")
                wiredBuilt?(key)
            }
            tabs.recycle = { view in
                counts.recycles += 1
                return wiredRecycle?(view) ?? false
            }
            defer {
                tabs.onPageBuilt = wiredBuilt
                tabs.recycle = wiredRecycle
                pool.makeSpare = nil
                // The run's record of the engine (decision 2026-11-16: each test says the engine that it ran with).
                let engines = counts.engines
                print("engine-of-test: UntouchedNewTabsShowOnePageTests \(install): \(engines.count) page views made, engines \(engines)")
            }
            counts.hadAtStart = pane.stripModel.tabs.map(\.id.rawValue)
            NewTabPage.open(in: pane, seed: nil)
            await frame(services)
            let pages = newTabCount(pane, services, since: counts.hadAtStart)
            try #require(pages == 1, "setup: the pane has \(pages) new New Tab tabs after one key")
            try #require(shownPage(pane) != nil, "setup: the pane shows no New Tab page at the frame after its first key")
            try await body(services, window, pane, counts)
        }
    }

    /// A run of New Tab keys with a frame after each, as a held key gives them. The rule is by the key; 12 keys keep
    /// the run small where each key makes a web view.
    @Test func aRunOfNewTabKeysMakesNoPageViewAndStartsNoRefill() async throws {
        try await Self.withAPaneThatShowsANewTab("cn-untouched-one-page-run") { services, _, pane, counts in
            let keys = 12
            let tabsBefore = pane.stripModel.tabs.count
            let builtBefore = counts.built.count
            let refillsBefore = counts.refills
            for _ in 0..<keys {
                NewTabPage.open(in: pane, seed: nil)
                await Self.frame(services)
            }
            let opened = pane.stripModel.tabs.count - tabsBefore
            try #require(opened == keys, "setup: the \(keys) keys added \(opened) tabs to the strip")
            let built = counts.built.count - builtBefore
            let refills = counts.refills - refillsBefore
            print("untouched new tabs, a run of \(keys) keys with a frame after each: \(built) page views built or adopted, \(refills) refill starts")
            #expect(built == 0, "a run of \(keys) New Tab keys made \(built) page views, want 0: the pane has its page")
            #expect(refills == 0, "a run of \(keys) New Tab keys started \(refills) refills of the pool while the keys came, want 0")
        }
    }

    /// The tab of each key is the pane's selection at the key's frame, and the pane shows for it the page view that
    /// it showed before the key, in the window: no ground and no page that must load.
    @Test func eachNewTabKeyShowsThePageViewThatThePaneShowedBeforeIt() async throws {
        try await Self.withAPaneThatShowsANewTab("cn-untouched-one-page-same") { services, window, pane, _ in
            let keys = 5
            var notShown = 0
            var otherViews = 0
            var notInTheWindow = 0
            for _ in 0..<keys {
                let before = try #require(Self.shownPage(pane), "setup: the pane shows no New Tab page before a key")
                let had = pane.stripModel.tabs.map(\.id.rawValue)
                NewTabPage.open(in: pane, seed: nil)
                await Self.frame(services)
                let selected = try #require(pane.stripModel.selectedID?.rawValue, "setup: the key selected no tab")
                try #require(!had.contains(selected), "setup: the key selected a tab that the pane had before it")
                try #require(services.agentTabs.isNewTabPage(selected), "setup: the key did not select its New Tab tab")
                let after = Self.shownPage(pane)
                if pane.currentTabKey != selected { notShown += 1 }
                if after !== before { otherViews += 1 }
                if after?.window !== window { notInTheWindow += 1 }
            }
            print("untouched new tabs, \(keys) keys with a frame after each: \(otherViews) keys changed the page view on screen; "
                + "\(notShown) keys' tabs were not shown at their frame; \(notInTheWindow) page views were not in the window")
            #expect(notShown == 0, "\(notShown) of \(keys) New Tab keys' tabs were not the pane's shown tab at the frame after the key")
            #expect(otherViews == 0, "after \(otherViews) of \(keys) New Tab keys the pane showed another page view than before the key, want 0")
            #expect(notInTheWindow == 0, "after \(notInTheWindow) of \(keys) New Tab keys the pane's page view was not in the window")
        }
    }

    /// Three New Tab tabs that no person used; then the page reports a first edit in the one on screen. That view is
    /// the touched tab's own from then; the 2 others have none of their own, so nothing of the first tab's draft can
    /// show in them, and at its frame one of them shows another view, which no person touched.
    @Test func aTouchOfOneUntouchedTabLeavesTheOthersWithNoPageViewOfTheirOwn() async throws {
        try await Self.withAPaneThatShowsANewTab("cn-untouched-one-page-touch") { services, _, pane, counts in
            let tabs = services.agentTabs
            let had = counts.hadAtStart
            for _ in 0..<2 {
                NewTabPage.open(in: pane, seed: nil)
                await Self.frame(services)
            }
            let shown = try #require(Self.shownPage(pane), "setup: the pane shows no New Tab page")
            _ = await shown.model.respond(to: AgentPaneRequest(body: ["method": "newTab.touched"]))
            try #require(shown.model.userTouched, "setup: the page did not take the touch")
            // The tabs by the strip now: the store can give a tab a new key between a key and here.
            let pages = pane.stripModel.tabs.map(\.id).filter { !had.contains($0.rawValue) && tabs.isNewTabPage($0.rawValue) }
            try #require(pages.count == 3, "setup: the pane has \(pages.count) new New Tab tabs, want 3")
            let touched = try #require(pane.stripModel.selectedID, "setup: the pane has no selection")
            let others = pages.filter { $0 != touched }
            try #require(others.count == 2, "setup: the pane's selection is not one of its 3 new New Tab tabs")
            #expect(tabs.existingView(touched.rawValue) === shown, "the touched tab's own page view is not the one that the pane showed at the touch")
            let own = others.filter { tabs.existingView($0.rawValue) != nil }.count
            print("untouched new tabs, a touch of one of 3: \(own) of the 2 other tabs have a page view of their own")
            #expect(own == 0, "\(own) of the 2 untouched New Tab tabs have a page view of their own after a touch of the third, want 0")
            pane.select(others[0])
            await Self.frame(services)
            let other = try #require(Self.shownPage(pane), "an untouched New Tab tab shows no page at its frame after a touch of another tab")
            #expect(other !== shown, "an untouched New Tab tab shows the page view that a person touched in another tab")
            #expect(!other.model.userTouched, "an untouched New Tab tab shows a page view that a person touched")
        }
    }

    /// The first touch makes the page view on screen the tab's own, in place: the pane shows the same view after it.
    /// This row is green before the change also (a tab had its own view from its key): it holds what must stay.
    @Test func theFirstTouchKeepsThePageViewOnScreenAndMakesItTheTabsOwn() async throws {
        try await Self.withAPaneThatShowsANewTab("cn-untouched-one-page-first-touch") { services, _, pane, _ in
            let shown = try #require(Self.shownPage(pane), "setup: the pane shows no New Tab page")
            _ = await shown.model.respond(to: AgentPaneRequest(body: ["method": "newTab.touched"]))
            try #require(shown.model.userTouched, "setup: the page did not take the touch")
            let key = try #require(pane.currentTabKey, "setup: the pane shows no tab")
            #expect(Self.shownPage(pane) === shown, "the first touch changed the page view that the pane shows")
            #expect(services.agentTabs.existingView(key) === shown, "the touched tab's own page view is not the one on screen")
        }
    }

    /// Two New Tab tabs that no person used; the one on screen closes. The pane's other such tab shows the same page
    /// view at its frame, and the close gives no page view to the pool: no page ends while a tab still shows it.
    @Test func aCloseOfAnUntouchedTabKeepsThePageViewOnScreenAndGivesNoneToThePool() async throws {
        try await Self.withAPaneThatShowsANewTab("cn-untouched-one-page-close") { services, _, pane, counts in
            let tabs = services.agentTabs
            let had = counts.hadAtStart
            NewTabPage.open(in: pane, seed: nil)
            await Self.frame(services)
            let pages = pane.stripModel.tabs.map(\.id).filter { !had.contains($0.rawValue) && tabs.isNewTabPage($0.rawValue) }
            try #require(pages.count == 2, "setup: the pane has \(pages.count) new New Tab tabs, want 2")
            let closed = try #require(pane.stripModel.selectedID, "setup: the pane has no selection")
            let others = pages.filter { $0 != closed }
            try #require(others.count == 1, "setup: the pane's selection is not one of its 2 new New Tab tabs")
            let shown = try #require(Self.shownPage(pane), "setup: the pane shows no New Tab page")
            let recyclesBefore = counts.recycles
            pane.close([closed])
            pane.select(others[0])
            await Self.frame(services)
            await Self.frame(services)
            let after = Self.shownPage(pane)
            let recycles = counts.recycles - recyclesBefore
            print("untouched new tabs, a close of one of 2: the pane shows \(after === shown ? "the same" : "another") page view; "
                + "\(recycles) page views went to the pool")
            #expect(pane.currentTabKey == others[0].rawValue, "the pane does not show its other New Tab tab after the close")
            #expect(after === shown, "after the close of an untouched New Tab tab the pane shows another page view for its other untouched tab")
            #expect(recycles == 0, "the close of an untouched New Tab tab gave \(recycles) page views to the pool while the pane has such a tab")
        }
    }

    // MARK: The key rows: each key goes through the app's dispatch

    /// What a key row gets: the app, its window, the pane, and the page view that the pane showed at the setup's end.
    @MainActor private struct Keyed {
        let services: AppServices
        let window: NSWindow
        let pane: PaneController
        let page: AgentPaneView
        var input: NewTabInputCoordinator { services.keyRouter.newTabInputCoordinator }
    }

    /// Each key that a hold of the app ran again, as the test's own replay (the one that the app's `init` takes) saw
    /// it: the key's letter, and the router's hold or the page view that had the keyboard at that time.
    @MainActor private final class Replays {
        var lines: [String] = []
        /// A row gives its tabs their names here, by the tab's key.
        var names: [String: String] = [:]
        /// Who has the window's keyboard: the fixture sets it when the app has its pane.
        var owner: (NSWindow) -> String = { _ in "a view before the setup's end" }
    }

    /// Who has the window's keyboard now, by the tab that owns the page view: a row's name of the tab, or its key.
    private static func keyboardOwner(_ window: NSWindow, _ pane: PaneController, _ services: AppServices, names: [String: String]) -> String {
        guard let view = keyboardPage(window) else {
            let has = String(describing: window.firstResponder)
            return "no page view (\(has))"
        }
        let owners = pane.stripModel.tabs.map(\.id.rawValue).filter { services.agentTabs.existingView($0) === view }
        if owners.isEmpty { return view === shownPage(pane) ? "a page view that no tab owns (the pane shows it)" : "a page view that no tab owns" }
        let named: [String] = owners.map { key in names[key] ?? "the tab \(key)" }
        return "the page view of " + named.joined(separator: " and ")
    }

    /// The New Tab tabs of the pane now.
    private static func newTabTabs(_ keyed: Keyed) -> [String] {
        keyed.pane.stripModel.tabs.map(\.id.rawValue).filter { keyed.services.agentTabs.isNewTabPage($0) }
    }

    private static func keyDown(_ character: String, keyCode: UInt16, flags: NSEvent.ModifierFlags = [], isARepeat: Bool = false,
                                in window: NSWindow) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                      windowNumber: window.windowNumber, context: nil, characters: character,
                                      charactersIgnoringModifiers: character, isARepeat: isARepeat, keyCode: keyCode))
    }

    /// One key through the app's dispatch: the key router, then the window when the router did not take it. Returns
    /// whether the router took it (a hold or a queue of the router has it then, or an action ran).
    @discardableResult
    private static func send(_ event: NSEvent, _ keyed: Keyed) -> Bool {
        if keyed.services.keyRouter.interceptKeyDown(event, in: keyed.window) { return true }
        keyed.window.sendEvent(event)
        return false
    }

    /// The Cmd-T key through the app's dispatch. Returns the key of the New Tab tab that it opened.
    private static func newTabKey(_ keyed: Keyed) throws -> String {
        let before = keyed.services.agentTabs.newTabPages.keys.map(\.key)
        let event = try Self.keyDown("t", keyCode: 17, flags: .command, in: keyed.window)
        let took = keyed.services.keyRouter.interceptKeyDown(event, in: keyed.window)
        let added = keyed.services.agentTabs.newTabPages.keys.map(\.key).filter { !before.contains($0) }
        try #require(took && added.count == 1,
                     "setup: the Cmd-T key opened \(added.count) New Tab tabs (the router took it: \(took)): this run proves nothing")
        return added[0]
    }

    /// The page view that has the window's keyboard, when one has it.
    private static func keyboardPage(_ window: NSWindow) -> AgentPaneView? {
        var view = window.firstResponder as? NSView
        while let current = view, !(current is AgentPaneView) { view = current.superview }
        return view as? AgentPaneView
    }

    /// The 2 reports of a page that the app waits for before it gives the page a key: its document focused its field
    /// (the type-ahead's rule), and its field is ready for the opening whose token the page has (the hold's rule).
    private static func reportReady(_ page: AgentPaneView) async {
        page.inputReadiness.report(true)
        guard let token = page.model.newTab?.inputToken else { return }
        _ = await page.model.respond(to: AgentPaneRequest(body: ["method": "newTab.inputReady", "params": ["token": token]]))
    }

    /// How many page views a person touched, of the own views of the pane's tabs and the view on screen.
    private static func touched(_ keyed: Keyed) -> Int {
        var views: [AgentPaneView] = []
        for key in keyed.pane.stripModel.tabs.map(\.id.rawValue) {
            if let view = keyed.services.agentTabs.existingView(key), !views.contains(where: { $0 === view }) { views.append(view) }
        }
        if let shown = Self.shownPage(keyed.pane), !views.contains(where: { $0 === shown }) { views.append(shown) }
        return views.filter { $0.model.userTouched }.count
    }

    /// The app with a pane that shows a New Tab tab, which no person used. Each page has an inert address: it loads
    /// nothing, so each report of a page here is the test's. No clock ends a hold of the New Tab field here: only a
    /// page's report, a chord or a close does. With `fieldReady` the page reported its field ready and has the
    /// window's keyboard; without it, the hold of the setup's key still waits for that report.
    private static func withAPaneWhosePageTakesKeys(_ install: String, fieldReady: Bool = true, replays: Replays? = nil,
                                                    _ body: (Keyed) async throws -> Void) async throws {
        let environment = [AgentPaneSource.devURLVariable: "http://127.0.0.1:9"]
        // A key that a hold runs again: the router gets it first, as in the app; the recorder says where it went.
        let record = replays ?? Replays()
        try await PasswordManagerRouteTests.withApp(agentPaneEnvironment: environment, heldKeyReplay: { event, window, router in
            let took = router.interceptKeyDown(event, in: window)
            let letter = event.characters ?? ""
            let place = took ? "the router took it again" : "to " + record.owner(window)
            record.lines.append("`\(letter)`: \(place)")
            if !took { window.sendEvent(event) }
        }) { services, _ in
            services.agentTabs.localHost = AgentSessionRef.host(installID: install)
            try #require(services.agentTabs.canHostChat, "this build has no New Tab page")
            let (window, pane) = try await NewTabOpenFramesTests.focusedPane(services)
            let pool = services.newTabSpares
            let input = services.keyRouter.newTabInputCoordinator
            record.owner = { [weak pane, weak services] window in
                guard let pane, let services else { return "a view after the app's end" }
                return Self.keyboardOwner(window, pane, services, names: record.names)
            }
            pool.dropAll()
            pool.makeSpare = { _ in nil }
            input.holdLimit = .seconds(600)
            input.scheduleDeadline = { _, _ in Task {} }
            NewTabPage.open(in: pane, seed: nil)
            await Self.frame(services)
            let page = try #require(Self.shownPage(pane), "setup: the pane shows no New Tab page at the frame after its first key")
            print("engine-of-test: UntouchedNewTabsShowOnePageTests \(install): the pane's page view has the engine \(page.engineName)")
            if fieldReady {
                await Self.reportReady(page)
                try #require(!input.isHolding(in: window), "setup: the hold of the setup's key did not end at the page's report: \(input.log)")
                let has = String(describing: window.firstResponder)
                try #require(Self.keyboardPage(window) === page, "setup: the page does not have the keyboard after its report (\(has))")
            } else {
                try #require(input.isHolding(in: window), "setup: the hold of the setup's key ended before the page's report: \(input.log)")
            }
            try #require(!page.model.userTouched, "setup: the page is touched before a key of the test")
            try await body(Keyed(services: services, window: window, pane: pane, page: page))
        }
    }

    /// New Tab keys (the second one a held key's repeat) and a select of another such tab touch no page.
    /// This row is green before the change also: it holds what must stay.
    @Test func newTabKeysAndASelectOfAnUntouchedTabAreNoTouch() async throws {
        try await Self.withAPaneWhosePageTakesKeys("cn-untouched-one-page-chords") { keyed in
            let tabs = keyed.services.agentTabs
            _ = try Self.newTabKey(keyed)
            let again = try Self.keyDown("t", keyCode: 17, flags: .command, isARepeat: true, in: keyed.window)
            let tookRepeat = keyed.services.keyRouter.interceptKeyDown(again, in: keyed.window)
            await Self.frame(keyed.services)
            let afterKeys = Self.touched(keyed)
            let selected = keyed.pane.stripModel.selectedID
            let other = try #require(keyed.pane.stripModel.tabs.map(\.id).first { $0 != selected && tabs.isNewTabPage($0.rawValue) },
                                     "setup: the pane has no second New Tab tab")
            keyed.pane.select(other)
            await Self.frame(keyed.services)
            let afterSelect = Self.touched(keyed)
            print("untouched new tabs, a New Tab key, its repeat (the router took it: \(tookRepeat)) and a select: "
                + "\(afterKeys) touched page views after the keys, \(afterSelect) after the select")
            #expect(afterKeys == 0, "New Tab keys touched \(afterKeys) page views, want 0: a chord is no use of a tab")
            #expect(afterSelect == 0, "a select of an untouched New Tab tab touched \(afterSelect) page views, want 0")
            #expect(!keyed.page.model.userTouched, "the page that the pane showed before the keys is touched after New Tab keys and a select")
        }
    }

    /// One text key in a New Tab tab whose page has the keyboard is one touch, in the key's turn: the host does not
    /// wait for the page's own report of an edit, which comes later than the next key.
    @Test func oneTextKeyInAnUntouchedTabIsOneTouchInTheKeysTurn() async throws {
        try await Self.withAPaneWhosePageTakesKeys("cn-untouched-one-page-text-key") { keyed in
            let tab = try #require(keyed.pane.currentTabKey, "setup: the pane shows no tab")
            let key = try Self.keyDown("x", keyCode: 7, in: keyed.window)
            let took = Self.send(key, keyed)
            let touched = Self.touched(keyed)
            print("untouched new tabs, one text key in a page that has the keyboard: the router took it: \(took); "
                + "\(touched) touched page views in the key's turn")
            #expect(keyed.page.model.userTouched, "a text key for an untouched New Tab page did not touch it in the key's turn")
            #expect(touched == 1, "one text key touched \(touched) page views, want 1")
            #expect(keyed.services.agentTabs.existingView(tab) === keyed.page, "the tab of the text key does not own the page view that got the key")
            #expect(Self.keyboardPage(keyed.window) === keyed.page, "the text key moved the keyboard off the page")
        }
    }

    /// A text key that the New Tab field's hold kept is no touch while it waits, and one touch when the hold gives
    /// it back at the page's report: a key that comes late is still a person's key.
    @Test func aTextKeyThatTheFieldsHoldGivesBackIsOneTouch() async throws {
        try await Self.withAPaneWhosePageTakesKeys("cn-untouched-one-page-give-back", fieldReady: false) { keyed in
            let key = try Self.keyDown("x", keyCode: 7, in: keyed.window)
            let took = Self.send(key, keyed)
            try #require(took && keyed.input.isHolding(in: keyed.window), "setup: the field's hold did not take the key: \(keyed.input.log)")
            let whileHeld = keyed.page.model.userTouched
            await Self.reportReady(keyed.page)
            let drained = keyed.input.log.contains { $0.hasPrefix("drained to field") }
            let touched = Self.touched(keyed)
            print("untouched new tabs, a text key that the field's hold gives back: touched while held: \(whileHeld); "
                + "the hold gave it to the field: \(drained); \(touched) touched page views after it")
            #expect(!whileHeld, "a key that waits in the field's hold touched the page before the page got it")
            #expect(!keyed.input.isHolding(in: keyed.window) && drained, "the hold did not give its key to the ready field: \(keyed.input.log)")
            #expect(keyed.page.model.userTouched, "a text key that the field's hold gave back did not touch the page")
            #expect(touched == 1, "a text key that the field's hold gave back touched \(touched) page views, want 1")
        }
    }

    /// New Tab, New Tab, then 3 text keys, in one turn of the main actor, in a pane whose page has the keyboard. The
    /// SECOND tab owns the page view that got the keys, and it is touched; the first tab has no page view of its own.
    @Test func threeTextKeysAfterTwoNewTabKeysTouchThePageForTheSecondTabOnly() async throws {
        try await Self.withAPaneWhosePageTakesKeys("cn-untouched-one-page-two-keys-text") { keyed in
            let tabs = keyed.services.agentTabs
            // One turn of the main actor: no wait between these 5 keys.
            let first = try Self.newTabKey(keyed)
            let second = try Self.newTabKey(keyed)
            var held = 0
            for character in ["x", "y", "z"] {
                let key = try Self.keyDown(character, keyCode: 0, in: keyed.window)
                if Self.send(key, keyed) { held += 1 }
            }
            let secondOwn = tabs.existingView(second)
            let firstOwn = tabs.existingView(first)
            let touchedInTurn = keyed.page.model.userTouched
            // The turn ends. The page on screen then reports ready (a page that already did changes nothing).
            await Self.frame(keyed.services)
            if let shown = Self.shownPage(keyed.pane) { await Self.reportReady(shown) }
            await Self.frame(keyed.services)
            let shown = Self.shownPage(keyed.pane)
            let dropped = keyed.input.log.filter { $0.hasPrefix("dropped") }
            print("untouched new tabs, New Tab, New Tab, 3 text keys in one turn: the router took \(held) of the 3; in the turn the "
                + "second tab owns \(secondOwn === keyed.page ? "the pane's page view" : secondOwn == nil ? "no page view" : "another page view")"
                + " (touched: \(touchedInTurn)); dropped: \(dropped)")
            #expect(secondOwn === keyed.page && touchedInTurn,
                    "in the turn of the 3 text keys the second tab does not own the pane's page view as a touched page")
            #expect(firstOwn == nil, "the first tab, which got no key, has a page view of its own in the keys' turn")
            #expect(shown != nil && Self.keyboardPage(keyed.window) === shown, "after the keys the page on screen does not have the keyboard")
            #expect(shown?.model.userTouched == true, "after the 3 text keys the page on screen is not touched")
            #expect(Self.touched(keyed) == 1, "the 3 text keys touched \(Self.touched(keyed)) page views, want 1")
            #expect(dropped.isEmpty, "the field's hold dropped keys: \(dropped)")
            #expect(!keyed.input.isHolding(in: keyed.window), "a hold of the New Tab field is still open: \(keyed.input.log)")
        }
    }

    /// New Tab, `a`, New Tab, `b` in one turn of the main actor. The second New Tab key opens its tab in its own
    /// turn, as the first one does. `a` is for the first tab: in its turn that tab owns the page view that has the
    /// keyboard, as a touched page. `b` is for the second tab: its page view is another one, which has the keyboard
    /// at the end. No key is dropped, and the page with `a` stays the first tab's.
    ///
    /// The print says where each letter went, also when a condition fails: at each letter, the router's hold or the
    /// view with the keyboard; then each key that a hold ran again, and what the New Tab field's hold logged.
    @Test func aLetterAfterEachOfTwoNewTabKeysGoesToThePageOfItsOwnTab() async throws {
        let replays = Replays()
        try await Self.withAPaneWhosePageTakesKeys("cn-untouched-one-page-letters", replays: replays) { keyed in
            let tabs = keyed.services.agentTabs
            let router = keyed.services.keyRouter
            // One turn of the main actor: no wait between these 4 keys.
            let first = try Self.newTabKey(keyed)
            replays.names[first] = "the first tab"
            let letterA = try Self.keyDown("a", keyCode: 0, in: keyed.window)
            let heldA = Self.send(letterA, keyed)
            let atA = heldA ? "a hold of the router" : Self.keyboardOwner(keyed.window, keyed.pane, keyed.services, names: replays.names)
            let keyboardAtA = Self.keyboardPage(keyed.window)
            let firstOwn = tabs.existingView(first)
            let touchedAtA = keyed.page.model.userTouched
            let beforeSecond = Self.newTabTabs(keyed)
            let secondKey = try Self.keyDown("t", keyCode: 17, flags: .command, in: keyed.window)
            let tookSecond = router.interceptKeyDown(secondKey, in: keyed.window)
            let inTurn = Self.newTabTabs(keyed).filter { !beforeSecond.contains($0) }
            for key in inTurn { replays.names[key] = "the second tab" }
            let letterB = try Self.keyDown("b", keyCode: 11, in: keyed.window)
            let heldB = Self.send(letterB, keyed)
            let atB = heldB ? "a hold of the router" : Self.keyboardOwner(keyed.window, keyed.pane, keyed.services, names: replays.names)
            let secondOwn = inTurn.first.flatMap { tabs.existingView($0) }
            // The turn ends. The page on screen then reports ready (a page that already did changes nothing).
            await Self.frame(keyed.services)
            let later = Self.newTabTabs(keyed).filter { !beforeSecond.contains($0) }
            for key in later where replays.names[key] == nil { replays.names[key] = "the second tab (it came after its key's turn)" }
            if let shown = Self.shownPage(keyed.pane) { await Self.reportReady(shown) }
            await Self.frame(keyed.services)
            let shown = Self.shownPage(keyed.pane)
            let owners = keyed.pane.stripModel.tabs.map(\.id.rawValue).filter { tabs.existingView($0) === keyed.page }
            let selected = keyed.pane.stripModel.selectedID?.rawValue
            let holdLog = keyed.input.log.filter { $0.hasPrefix("release") || $0.hasPrefix("dropped") || $0.hasPrefix("drained") }
            let dropped = holdLog.filter { $0.hasPrefix("dropped") }
            let atEnd = Self.keyboardOwner(keyed.window, keyed.pane, keyed.services, names: replays.names)
            let holdsNewTab = keyed.input.isHolding(in: keyed.window)
            let holdsCreation = router.creationInputCoordinator.isHolding(in: keyed.window)
            var ownsAtA = "another page view"
            if firstOwn === keyed.page { ownsAtA = "the pane's page view" } else if firstOwn == nil { ownsAtA = "no page view" }
            print("untouched new tabs, New Tab, a, New Tab, b in one turn: the second New Tab key (the router took it: \(tookSecond)) "
                + "opened \(inTurn.count) tabs in its own turn and \(later.count) by the end. `a` at its key: \(atA); `b` at its key: "
                + "\(atB). Keys that a hold ran again: \(replays.lines). The New Tab field's hold: \(holdLog). The keyboard at the "
                + "end: \(atEnd). A New Tab hold is open: \(holdsNewTab); a creation hold is open: \(holdsCreation). At `a` the first "
                + "tab owns \(ownsAtA) (touched: \(touchedAtA)); \(owners.count) tabs own the pane's first page view at the end")
            #expect(tookSecond && inTurn.count == 1, "the second New Tab key opened \(inTurn.count) tabs in its own turn, want 1")
            #expect(keyboardAtA === keyed.page, "`a`: the pane's page view does not have the keyboard at the letter")
            #expect(firstOwn === keyed.page && touchedAtA,
                    "`a`: in its turn the first tab does not own the page view with the keyboard as a touched page")
            #expect(secondOwn !== keyed.page, "`b`: the second tab took the page view that `a` went to")
            #expect(shown != nil && shown !== keyed.page,
                    "`b`: the second tab shows no page view, or the one that has the first tab's `a`")
            #expect(shown != nil && Self.keyboardPage(keyed.window) === shown,
                    "`b`: the second tab's page view does not have the keyboard at the end")
            #expect(shown != nil && selected.flatMap({ tabs.existingView($0) }) === shown,
                    "`b`: the tab that owns the page view with the keyboard at the end is not the second tab")
            #expect(dropped.isEmpty, "a letter was dropped: \(dropped)")
            #expect(owners.count == 1 && owners.first != selected,
                    "the page view with `a` is not the own view of one tab that is not the selected one")
            #expect(!keyed.input.isHolding(in: keyed.window), "a hold of the New Tab field is still open: \(keyed.input.log)")
        }
    }

    /// New Tab, 2 text keys, Close Tab in one turn of the main actor. The Close Tab key closes the tab of the text in
    /// its own turn: the pane then has one New Tab tab less. The pane's New Tab tabs that got no key then show a page
    /// view that no key touched. This row is green before the change also (the hold drops the 2 keys at the chord): it
    /// holds what must stay when the page takes them at once.
    ///
    /// Each count is read in the turn of its key, by the keys that the pane's tabs have then: a tab's key can change
    /// when the daemon answers its creation, which is after the turn.
    @Test func textAfterANewTabKeyThenACloseKeyLeavesTheOtherTabAPageThatNoKeyTouched() async throws {
        try await Self.withAPaneWhosePageTakesKeys("cn-untouched-one-page-text-close") { keyed in
            // One turn of the main actor: no wait between these 4 keys.
            let atStart = Self.newTabTabs(keyed)
            let first = try Self.newTabKey(keyed)
            let beforeClose = Self.newTabTabs(keyed)
            var held = 0
            for character in ["l", "s"] {
                let key = try Self.keyDown(character, keyCode: 0, in: keyed.window)
                if Self.send(key, keyed) { held += 1 }
            }
            let close = try Self.keyDown("w", keyCode: 13, flags: .command, in: keyed.window)
            let resolved = keyed.services.registry.resolveShortcut(for: close)?.id.rawValue
            try #require(resolved == "closeTab",
                         "Cmd-W does not resolve to Close Tab here (\(String(describing: resolved))): this run proves nothing")
            let tookClose = Self.send(close, keyed)
            let afterClose = Self.newTabTabs(keyed)
            let closedInTurn = !keyed.pane.stripModel.tabs.map(\.id.rawValue).contains(first)
            // The turn ends.
            await Self.frame(keyed.services)
            await Self.frame(keyed.services)
            let left = Self.newTabTabs(keyed)
            if let other = left.first {
                keyed.pane.select(StripTabID(other))
                await Self.frame(keyed.services)
            }
            let shown = Self.shownPage(keyed.pane)
            let touched = Self.touched(keyed)
            let dropped = keyed.input.log.filter { $0.hasPrefix("dropped") }
            print("untouched new tabs, New Tab, 2 text keys, Close Tab in one turn: the pane has \(atStart.count) New Tab tabs at the "
                + "start, \(beforeClose.count) after the New Tab key, \(afterClose.count) in the turn of the close key (the router took "
                + "\(held) of the 2 text keys and the close key: \(tookClose); the tab of the text is closed in that turn: "
                + "\(closedInTurn)), \(left.count) at the end; \(touched) touched page views are left; the hold: \(dropped)")
            #expect(beforeClose.count == atStart.count + 1, "setup: the New Tab key did not add one New Tab tab to the pane")
            #expect(closedInTurn && afterClose.count == beforeClose.count - 1,
                    "the Close Tab key left \(afterClose.count) New Tab tabs in its turn, want one less than \(beforeClose.count)")
            #expect(left.count == beforeClose.count - 1,
                    "\(left.count) New Tab tabs are left at the end, want one less than \(beforeClose.count)")
            #expect(shown != nil, "the pane shows no page of a New Tab tab at its frame after the close")
            #expect(shown?.model.userTouched == false, "the pane shows a page view that the closed tab's text touched")
            #expect(touched == 0, "\(touched) touched page views are left after the close of the tab of the text, want 0")
        }
    }

    /// A text key for a New Tab page whose field reported ready, but whose document did not, waits in the router's
    /// queue of typed text: the router takes it and gives it to the field at the document's report. It is one touch
    /// in the key's turn, as a key that the page gets at once: the person typed it for this tab.
    @Test func aTextKeyThatWaitsForThePagesDocumentIsOneTouchInTheKeysTurn() async throws {
        try await Self.withAPaneWhosePageTakesKeys("cn-untouched-one-page-type-ahead", fieldReady: false) { keyed in
            let router = keyed.services.keyRouter
            // The field's report alone ends the hold of the setup's key; the document's report does not come in this row.
            let token = try #require(keyed.page.model.newTab?.inputToken, "setup: the page has no token of its opening")
            _ = await keyed.page.model.respond(to: AgentPaneRequest(body: ["method": "newTab.inputReady", "params": ["token": token]]))
            try #require(!keyed.input.isHolding(in: keyed.window), "setup: the hold did not end at the field's report: \(keyed.input.log)")
            try #require(!keyed.page.inputReadiness.isReady, "setup: the page's document is ready with no report of the test")
            try #require(!keyed.page.model.userTouched, "setup: the field's report touched the page")
            let key = try Self.keyDown("x", keyCode: 7, in: keyed.window)
            let took = Self.send(key, keyed)
            let waits = router.typeAheadFocus != nil
            let has = String(describing: keyed.window.firstResponder)
            try #require(took && waits, "setup: the queue of typed text did not take the key (the router took it: \(took); keyboard: \(has))")
            let touched = Self.touched(keyed)
            print("untouched new tabs, one text key that waits for the page's document: the router took it: \(took); "
                + "\(touched) touched page views in the key's turn")
            #expect(keyed.page.model.userTouched, "a text key that waits for an untouched New Tab page's document did not touch the page in its turn")
            #expect(touched == 1, "one text key that waits for the page's document touched \(touched) page views, want 1")
        }
    }
}
