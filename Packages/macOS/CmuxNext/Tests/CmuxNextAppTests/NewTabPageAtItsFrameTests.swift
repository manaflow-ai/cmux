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
/// - a run of keys in one turn makes no page view before a frame and one at most after it;
/// - a tab closed before its frame makes no page view;
/// - a key typed before that frame still waits for the new tab's field;
/// - a tab closed before that frame takes its typed keys with it.
///
/// Frames are the app's own. A test waits for one by an event: a probe that stands in the scheduler's queue behind
/// the pane. No wait polls and no wait reads a clock.
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

    /// Returns when the scheduler's next frame showed what waited for it.
    private static func frame(_ services: AppServices) async {
        let probe = FrameProbe()
        await withCheckedContinuation { (shown: CheckedContinuation<Void, Never>) in
            probe.onShow = { shown.resume() }
            services.presentation.setNeedsShowSelected(probe)
        }
    }

    /// The app with an empty pool of prewarmed pages, so each New Tab page is made cold. `body` gets the pane that
    /// Cmd-T opens in, its window, and the count of page views built since the setup.
    private static func withAnEmptyPool(_ install: String,
                                        _ body: (AppServices, NSWindow, PaneController, () -> Int) async throws -> Void) async throws {
        try await PasswordManagerRouteTests.withApp { services, _ in
            services.agentTabs.localHost = AgentSessionRef.host(installID: install)
            try #require(services.agentTabs.canHostChat, "this build has no New Tab page")
            let (window, pane) = try await NewTabOpenFramesTests.focusedPane(services)
            let pool = services.newTabSpares, tabs = services.agentTabs
            pool.dropAll()
            pool.makeSpare = { _ in nil }
            // Each page view that the tab store builds or adopts tells this; the app's own listener still hears it.
            var built = 0
            let wired = tabs.onPageBuilt
            tabs.onPageBuilt = { key in
                built += 1
                wired?(key)
            }
            defer {
                tabs.onPageBuilt = wired
                pool.makeSpare = nil
            }
            try await body(services, window, pane) { built }
        }
    }

    /// Four New Tab keys in one turn of the main thread: no frame comes between them, so no tab but the last is
    /// ever shown. Then three keys with a frame after each.
    @Test func aRunOfNewTabKeysInOneTurnMakesNoPageBeforeAFrameAndOneAtMostAfterIt() async throws {
        try await Self.withAnEmptyPool("cn-page-at-frame-run") { services, _, pane, built in
            let tabs = services.agentTabs
            let pages = Set(tabs.newTabPages.keys)
            for _ in 0..<4 { NewTabPage.open(in: pane, seed: nil) }
            let opened = tabs.newTabPages.keys.filter { !pages.contains($0) }.count
            try #require(opened == 4, "the 4 keys opened \(opened) New Tab pages")
            #expect(built() == 0, "\(built()) page views were made in the keys' own turn, before a frame showed a tab")
            await Self.frame(services)
            #expect(built() <= 1, "\(built()) page views were made for 4 keys of one turn and one frame")
            // The tab that the pane shows gets its page: at that frame, or at a later one when the launch still held it.
            for _ in 0..<240 where built() == 0 { await Self.frame(services) }
            #expect(built() == 1, "\(built()) page views for the one tab that a frame showed")
            #expect(pane.currentTabKey == pane.stripModel.selectedID?.rawValue, "the pane does not show its selected tab")

            // Keys over frames: a page for each frame at most.
            let before = built()
            for _ in 0..<3 {
                NewTabPage.open(in: pane, seed: nil)
                await Self.frame(services)
            }
            #expect(built() - before <= 3, "\(built() - before) page views were made for 3 keys over 3 frames")
        }
    }

    /// The tab closes in the turn of its key: no frame showed it, and no page view is made for it.
    @Test func aNewTabClosedBeforeItsFrameMakesNoPage() async throws {
        try await Self.withAnEmptyPool("cn-page-at-frame-close") { services, _, pane, built in
            NewTabPage.open(in: pane, seed: nil)
            let made = try #require(pane.stripModel.selectedID, "the open selected no tab")
            try #require(services.agentTabs.isNewTabPage(made.rawValue), "the open did not select its New Tab page")
            pane.close([made])
            #expect(pane.stripModel.selectedID != made, "the closed tab is still the pane's selection")
            await Self.frame(services)
            await Self.frame(services)
            #expect(built() == 0, "\(built()) page views were made for a tab that closed before a frame showed it")
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
