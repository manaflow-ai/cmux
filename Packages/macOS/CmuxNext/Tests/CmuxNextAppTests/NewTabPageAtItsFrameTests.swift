import AppKit
@testable import CmuxNextAgentPane
@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextTestSupport
import Foundation
import Testing

/// A New Tab key with no prewarmed page to adopt made its page view (a web view) in the key's own turn of the main
/// thread: the create path showed the new tab directly, round the frame rule that every other selection obeys
/// (`ContentPresentationScheduler`: only the selection a pane has at frame time is shown, one new surface a frame
/// at most). A held Cmd-T so made one page for each key, also for a tab that no frame showed.
///
/// The frame rule for a new tab's page (decision 2026-11-16): the tab shows in the strip at its key; its page view
/// is made at the next frame, for the tab that the pane has selected then. These hold it with an empty pool, so each
/// page here is a cold one:
///
/// - a run of keys in one turn makes no page view before a frame and one at the next frame;
/// - a tab closed before its frame gets no page view;
/// - a key typed before that frame still waits for the new tab's field;
/// - a tab closed before that frame takes its typed keys with it.
///
/// Frames are the app's own. A test waits for one by an event: a probe that stands in the scheduler's queue behind
/// the pane. No wait of these tests polls and none reads a clock. (The shared setup that starts the app and finds
/// its focused pane is the base's, and waits in its own way before a test's first line.)
///
/// The engine: each page view here is a real one, and each test prints the engine of each page view that it made
/// (`engine-of-test:` in the run's output). The package's tests have no Chromium host, so that engine is WebKit: a
/// pass here holds the rule of the host code, and is no proof of the look or the times of a Chromium page.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"),
                  .closesItsWindows)
struct NewTabPageAtItsFrameTests {
    /// Stands in the presentation scheduler's queue: its show is the event that a frame's drain ran. Its content is
    /// alive, so it spends nothing of the frame's budget, and it has no focus, so the focused pane shows before it.
    @MainActor private final class FrameProbe: PresentablePane {
        var onShow: () -> Void = {}
        var selectedContentIsAlive: Bool { true }
        var isFocusedInWorkspace: Bool { false }
        func showSelected() { onShow() }
        func showWhileWaiting() {}
    }

    /// Returns when the scheduler's next frame showed what waited for it. `NewTabRepeatKeyTests` waits by it too.
    static func frame(_ services: AppServices) async {
        let probe = FrameProbe()
        await withCheckedContinuation { (shown: CheckedContinuation<Void, Never>) in
            probe.onShow = { shown.resume() }
            services.presentation.setNeedsShowSelected(probe)
        }
    }

    /// A page view that the tab store built or adopted since the setup: its tab's key, if its tab was the pane's
    /// selection then, and what it was then in words (its engine, if its tab is a New Tab page, the selection).
    typealias BuiltPage = (key: String, selected: Bool, note: String)

    /// The app with an empty pool of prewarmed pages, so each New Tab page is made cold. `body` gets the pane that
    /// Cmd-T opens in, its window, and the count of page views built since the setup. `NewTabRepeatKeyTests` runs in it too.
    static func withAnEmptyPool(_ install: String,
                                        _ body: (AppServices, NSWindow, PaneController, () -> Int) async throws -> Void) async throws {
        try await withThePagesOfAnEmptyPool(install) { services, window, pane, pages in
            try await body(services, window, pane) { pages().count }
        }
    }

    /// `withAnEmptyPool` with each built page view by its tab, in the order of the builds. `NewTabRepeatKeyTests` runs in it too.
    static func withThePagesOfAnEmptyPool(_ install: String,
                                          _ body: (AppServices, NSWindow, PaneController, @escaping () -> [BuiltPage]) async throws -> Void) async throws {
        try await PasswordManagerRouteTests.withApp { services, _ in
            services.agentTabs.localHost = AgentSessionRef.host(installID: install)
            try #require(services.agentTabs.canHostChat, "this build has no New Tab page")
            let (window, pane) = try await NewTabOpenFramesTests.focusedPane(services)
            let pool = services.newTabSpares, tabs = services.agentTabs
            pool.dropAll()
            pool.makeSpare = { _ in nil }
            // The next Cmd-N's reservation is idle work of the app (`WorkspaceSpareSlot`): in the app's first idle frame it
            // builds one page view, for a tab that no pane has. The fixture makes the reservation now, by the app's own
            // function and before it counts, so that no test counts that page view by chance (decision 2026-11-16).
            _ = try #require(tabs.reserveWorkspace(on: services.daemon, cwd: nil), "fixture: no Cmd-N workspace was reserved")
            // Each page view that the tab store builds or adopts tells this; the app's own listener still hears it.
            var pages: [BuiltPage] = [], engines: [String] = []
            let wired = tabs.onPageBuilt
            tabs.onPageBuilt = { key in
                let engine = tabs.existingView(key)?.engineName ?? "no view"
                let kind = tabs.isNewTabPage(key) ? "a New Tab page" : "no New Tab page"
                let isSelected = pane.stripModel.selectedID?.rawValue == key
                let selected = isSelected ? "the pane's selection" : "not the pane's selection"
                pages.append((key: key, selected: isSelected, note: "\(engine), \(kind), \(selected)"))
                engines.append(engine)
                wired?(key)
            }
            defer {
                tabs.onPageBuilt = wired
                pool.makeSpare = nil
                // The run's record of the engine (decision 2026-11-16: each test says the engine that it ran with).
                print("engine-of-test: NewTabPageAtItsFrameTests \(install): \(engines.count) page views made, engines \(engines)")
                print("pages-of-test: NewTabPageAtItsFrameTests \(install): \(pages)")
            }
            try await body(services, window, pane) { pages }
        }
    }

    /// Four New Tab keys in one turn of the main thread: no frame comes between them, so no tab but the last is
    /// ever shown, and that one gets its page at the next frame. Then three keys with a frame after each: no page
    /// in a key's own turn, and its page at its frame.
    @Test func aRunOfNewTabKeysInOneTurnMakesNoPageBeforeAFrameAndOneAtMostAfterIt() async throws {
        try await Self.withAnEmptyPool("cn-page-at-frame-run") { services, _, pane, built in
            let tabs = services.agentTabs
            let pages = Set(tabs.newTabPages.keys)
            for _ in 0..<4 { NewTabPage.open(in: pane, seed: nil) }
            let opened = tabs.newTabPages.keys.filter { !pages.contains($0) }.count
            try #require(opened == 4, "the 4 keys opened \(opened) New Tab pages")
            #expect(built() == 0, "\(built()) page views were made in the keys' own turn, before a frame showed a tab")
            await Self.frame(services)
            // The one tab that the pane has selected gets its page at that frame: not before it and not after it.
            #expect(built() == 1, "\(built()) page views were made for 4 keys of one turn at the one frame after them")
            #expect(pane.currentTabKey == pane.stripModel.selectedID?.rawValue, "the pane does not show its selected tab")

            // Keys over frames: no page in a key's own turn, and one page at its frame.
            for index in 1...3 {
                let before = built()
                NewTabPage.open(in: pane, seed: nil)
                #expect(built() == before, "key \(index) of 3 made \(built() - before) page views in its own turn")
                await Self.frame(services)
                #expect(built() - before == 1, "key \(index) of 3 had \(built() - before) page views at its frame")
            }
        }
    }

    /// The tab closes in the turn of its key: no frame showed it, and no page view is made for it. The close gives
    /// the pane's selection back to a tab that the pane had before the key; a page view for THAT tab at the frame is
    /// the frame rule itself and is no fault. So each page view here must be for a tab of the pane: one that the pane
    /// had before the key, or one that the pane had selected when the view was made AND still has after the 2 frames
    /// (the store can give a tab a new key meanwhile). The closed tab was the pane's selection in the key's own turn,
    /// so the selection alone lets no page view pass, and the test asserts first that no page view exists before the
    /// close. The closed tab must not be in the pane again: the pane has as many tabs after the 2 frames as before
    /// the key. The failure names each built page by its tab.
    @Test func aNewTabClosedBeforeItsFrameMakesNoPage() async throws {
        try await Self.withThePagesOfAnEmptyPool("cn-page-at-frame-close") { services, _, pane, pages in
            let had = pane.stripModel.tabs.map(\.id.rawValue)
            let selectedBefore = pane.stripModel.selectedID?.rawValue ?? "no tab"
            NewTabPage.open(in: pane, seed: nil)
            let made = try #require(pane.stripModel.selectedID, "the open selected no tab")
            try #require(services.agentTabs.isNewTabPage(made.rawValue), "the open did not select its New Tab page")
            try #require(!had.contains(made.rawValue), "the open selected a tab that the pane had before the key")
            #expect(pages().isEmpty, "\(pages().count) page views were made in the key's own turn, before the close: \(pages())")
            pane.close([made])
            #expect(pane.stripModel.selectedID != made, "the closed tab is still the pane's selection")
            let atTheClose = pages().count
            await Self.frame(services)
            let atFrameOne = pages().count
            await Self.frame(services)
            // The run's record, on a pass also: which tab each page view was for, and what the pane has now.
            let built = pages()
            let tabsNow = pane.stripModel.tabs.map(\.id.rawValue)
            let selectedNow = pane.stripModel.selectedID?.rawValue ?? "no tab"
            let shownNow = pane.currentTabKey ?? "no tab"
            var state = "the closed tab \(made.rawValue); the pane's tabs before the key \(had), its selection then \(selectedBefore); "
            state += "page views at the close \(atTheClose), after frame 1 \(atFrameOne), after frame 2 \(built.count): \(built); "
            state += "the pane's tabs now \(tabsNow), its selection \(selectedNow), its shown tab \(shownNow)"
            print("state-of-test: NewTabPageAtItsFrameTests cn-page-at-frame-close: \(state)")
            #expect(tabsNow.count == had.count, "the pane has \(tabsNow.count) tabs after the close, and had \(had.count) before the key: \(state)")
            let notOfThePane = built.filter { !had.contains($0.key) && !($0.selected && tabsNow.contains($0.key)) }
            #expect(notOfThePane.isEmpty, "\(notOfThePane.count) page views were made for a tab that is not the pane's: \(state)")
        }
    }

    /// A person types at once after Cmd-T. The window's key hold has the key until the page's field is ready; the
    /// hold must not end because the pane shows no tab in the frame before the page's view exists.
    @Test func aKeyTypedBeforeTheFrameWaitsForTheNewTabsField() async throws {
        try await Self.withAnEmptyPool("cn-page-at-frame-key") { services, window, pane, _ in
            let input = services.keyRouter.newTabInputCoordinator
            NewTabPage.open(in: pane, seed: nil)
            try #require(input.isHolding(in: window), "the open began no key hold")
            let key = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                    windowNumber: window.windowNumber, context: nil, characters: "a",
                                                    charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0))
            let held = input.capture(key, in: window)
            #expect(held, "the key typed before the new tab's frame was not held for its field: \(input.log.suffix(4))")
            #expect(input.isHolding(in: window), "the hold ended at that key: \(input.log.suffix(4))")
            await Self.frame(services)
            #expect(!input.log.contains { $0.contains("not owned") }, "the hold ended as not owned: \(input.log.suffix(6))")
            // The held key goes no further than this test: the hold drops it with the page's tab.
            if let shown = pane.currentTabKey { input.drop(tab: shown, in: window) }
        }
    }

    /// The tab closes before its frame, with a key typed for it: the key goes with the tab. It never reaches what
    /// had the keyboard before Cmd-T.
    @Test func aNewTabClosedBeforeItsFrameTakesItsTypedKeyWithIt() async throws {
        try await Self.withAnEmptyPool("cn-page-at-frame-close-key") { services, window, pane, _ in
            let input = services.keyRouter.newTabInputCoordinator
            NewTabPage.open(in: pane, seed: nil)
            let made = try #require(pane.stripModel.selectedID, "the open selected no tab")
            let key = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                    windowNumber: window.windowNumber, context: nil, characters: "a",
                                                    charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0))
            try #require(input.capture(key, in: window), "the key typed before the new tab's frame was not held: \(input.log.suffix(4))")
            pane.close([made])
            #expect(!input.isHolding(in: window), "the hold outlived its closed tab: \(input.log.suffix(4))")
            #expect(input.log.contains { $0.contains("closed before created") }, "the hold did not end with its tab: \(input.log.suffix(6))")
        }
    }
}
