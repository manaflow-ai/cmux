import AppKit
@testable import CmuxNextAgentPane
@testable import CmuxNextApp
import CmuxNextDaemon
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
}
