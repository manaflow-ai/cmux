import AppKit
@testable import CmuxNextBrowser
import CmuxNextWakeups
import Foundation
import Testing

/// A renderer hang is that tab's own prompt, under Chrome's visibility rules
/// (feature `chromiumHangFollowsVisibility`, ``CEFRendererHang``). Chrome drops a hang reported for a
/// hidden tab (`WebContentsImpl::RendererUnresponsive`), stops the hang timer on `WasHidden` and
/// starts it again on `WasShown`. cmux keeps no timer: a hidden tab's hang is held, and the show
/// answers Wait (`cmux_shim_unresponsive_reply(browser, 0)`), which restarts Chromium's
/// `kHungRendererDelay`. The shim's events go through the real runtime and tabs; the shim is a spy.
@MainActor @Suite(.serialized) struct CEFRendererHangTests {
    // MARK: Steps

    @Test func aHangOnAShownTabPromptsAndHoldsNothing() {
        var hang = CEFRendererHang()
        #expect(hang.reported(shown: true) == .prompt)
        #expect(!hang.isHeld)
    }

    @Test func aHangOnAHiddenTabIsHeldUntilTheTabShowsThenRestartsTheTimerOnce() {
        var hang = CEFRendererHang()
        #expect(hang.reported(shown: false) == .nothing, "no prompt for a hidden tab")
        #expect(hang.isHeld)
        #expect(hang.shownChanged(shown: false, prompting: false) == .nothing, "another hide changes nothing")
        #expect(hang.shownChanged(shown: true, prompting: false) == .restartTimer)
        #expect(!hang.isHeld)
        #expect(hang.shownChanged(shown: true, prompting: false) == .nothing, "one restart per held hang")
    }

    @Test func aPromptingTabThatHidesWithdrawsItsPromptAndHoldsTheHang() {
        var hang = CEFRendererHang()
        _ = hang.reported(shown: true)
        #expect(hang.shownChanged(shown: false, prompting: true) == .withdraw)
        #expect(hang.isHeld)
        #expect(hang.shownChanged(shown: true, prompting: false) == .restartTimer)
    }

    @Test func anEndedHangIsNotRestartedWhenTheTabShows() {
        var hang = CEFRendererHang()
        _ = hang.reported(shown: false)
        hang.ended()
        #expect(!hang.isHeld)
        #expect(hang.shownChanged(shown: true, prompting: false) == .nothing)
        #expect(hang.shownChanged(shown: false, prompting: false) == .nothing, "a hidden tab with no prompt holds nothing")
    }

    // MARK: Tabs

    /// A `while(true){}` page: its tab's prompt shows, and the other shown tab's never does.
    @Test func aHangPromptsInItsOwnTabOnly() throws {
        let rig = try Rig(followsVisibility: true)
        let hung = try rig.shownTab(browser: 10)
        let other = try rig.shownTab(browser: 11)

        rig.runtime.handle(.renderUnresponsive(browser: 10))

        #expect(hung.state.isUnresponsive)
        #expect(!other.state.isUnresponsive, "another tab never shows the hang")
        #expect(HangReplySpy.replies.isEmpty, "the prompt waits for the person")
    }

    @Test func aHangReportedWhileHiddenShowsNothingAndTheShowRestartsTheTimer() throws {
        let rig = try Rig(followsVisibility: true)
        let tab = try rig.shownTab(browser: 10)
        tab.contentDidDisappear()

        rig.runtime.handle(.renderUnresponsive(browser: 10))
        #expect(!tab.state.isUnresponsive, "a hidden tab shows no prompt (WebContentsImpl::RendererUnresponsive)")
        #expect(tab.rendererHang.isHeld)
        #expect(HangReplySpy.replies.isEmpty, "no timer runs for a hidden tab: nothing restarts it")

        tab.contentDidAppear(in: tab.container)
        #expect(HangReplySpy.replies.map({ $0.browser }) == [10])
        #expect(HangReplySpy.replies.map({ $0.terminate }) == [0], "Wait: kHungRendererDelay again from the show")
        #expect(!tab.state.isUnresponsive, "the prompt waits for the restarted timer")

        rig.runtime.handle(.renderUnresponsive(browser: 10))
        #expect(tab.state.isUnresponsive, "the restarted timer's report prompts")
    }

    @Test func hidingAPromptingTabTakesThePromptDownAndShowingItAgainRestartsTheTimer() throws {
        let rig = try Rig(followsVisibility: true)
        let tab = try rig.shownTab(browser: 10)
        rig.runtime.handle(.renderUnresponsive(browser: 10))
        try #require(tab.state.isUnresponsive)

        tab.setContentVisible(false)
        #expect(!tab.state.isUnresponsive, "WasHidden takes the hang back")
        #expect(tab.rendererHang.isHeld)
        tab.setContentVisible(true)
        #expect(HangReplySpy.replies.map({ $0.terminate }) == [0])
        #expect(!tab.rendererHang.isHeld)
    }

    /// A Chromium that heard the hide takes the hang back itself (RENDER_RESPONSIVE) and restarts its
    /// own timer on the show: cmux answers nothing then.
    @Test func aHangChromiumTookBackWhileHiddenIsNotAnsweredOnTheShow() throws {
        let rig = try Rig(followsVisibility: true)
        let tab = try rig.shownTab(browser: 10)
        rig.runtime.handle(.renderUnresponsive(browser: 10))
        tab.setContentVisible(false)
        rig.runtime.handle(.renderResponsive(browser: 10))
        #expect(!tab.rendererHang.isHeld)

        tab.setContentVisible(true)
        #expect(HangReplySpy.replies.isEmpty)
        #expect(!tab.state.isUnresponsive)
    }

    @Test func aRendererExitDropsAHeldHang() throws {
        let rig = try Rig(followsVisibility: true)
        let tab = try rig.shownTab(browser: 10)
        tab.contentDidDisappear()
        rig.runtime.handle(.renderUnresponsive(browser: 10))
        rig.runtime.handle(.renderTerminated(browser: 10, status: 2, code: Int(SIGKILL), text: "", end: .first))
        #expect(!tab.rendererHang.isHeld)

        tab.contentDidAppear(in: tab.container)
        #expect(HangReplySpy.replies.isEmpty, "no hang left to restart")
    }

    /// Feature off: every hang prompts at once, hidden or not, and a show answers nothing (as before).
    @Test func withoutTheVisibilityRulesAHiddenTabPromptsAtOnce() throws {
        let rig = try Rig(followsVisibility: false)
        let tab = try rig.shownTab(browser: 10)
        tab.contentDidDisappear()

        rig.runtime.handle(.renderUnresponsive(browser: 10))
        #expect(tab.state.isUnresponsive)
        #expect(!tab.rendererHang.isHeld)
        tab.contentDidAppear(in: tab.container)
        #expect(HangReplySpy.replies.isEmpty)
        #expect(tab.state.isUnresponsive)
    }

    /// A minimized window's tab is not visible (Chrome's `WebContents::GetVisibility()`): its hang is
    /// held, and the window's show answers Wait, so the timer runs a full `kHungRendererDelay` from it.
    @Test func aHangInAMinimizedWindowIsHeldAndTheWindowsShowRestartsTheTimer() throws {
        let rig = try Rig(followsVisibility: true)
        let tab = try rig.shownTab(browser: 10)
        rig.window.change(\.isShown, false, NSWindow.didMiniaturizeNotification)
        #expect(!tab.showsForRendererHang)

        rig.runtime.handle(.renderUnresponsive(browser: 10))
        #expect(!tab.state.isUnresponsive, "a minimized window's tab shows no prompt")
        #expect(tab.rendererHang.isHeld)
        #expect(HangReplySpy.replies.isEmpty, "no timer runs while the window is hidden")

        rig.window.change(\.isShown, true, NSWindow.didDeminiaturizeNotification)
        #expect(HangReplySpy.replies.map({ $0.browser }) == [10])
        #expect(HangReplySpy.replies.map({ $0.terminate }) == [0], "Wait: kHungRendererDelay again from the window's show")
        #expect(!tab.rendererHang.isHeld)
        #expect(!tab.state.isUnresponsive, "the prompt waits for the restarted timer")
    }

    /// A covered window, by AppKit or by an opaque cmux window over it (``WindowOcclusionFamily``),
    /// takes its tab's prompt down; uncovering it answers Wait.
    @Test func coveringAPromptingTabsWindowTakesThePromptDownAndUncoveringRestartsTheTimer() throws {
        let rig = try Rig(followsVisibility: true)
        let tab = try rig.shownTab(browser: 10)
        rig.runtime.handle(.renderUnresponsive(browser: 10))
        try #require(tab.state.isUnresponsive)

        let family = WindowOcclusionFamily.of(rig.window.window)
        family.set(occluded: true)
        #expect(!tab.state.isUnresponsive, "an occluded window's tab is not visible")
        #expect(tab.rendererHang.isHeld)
        family.set(occluded: false)
        #expect(HangReplySpy.replies.map({ $0.terminate }) == [0])
        #expect(!tab.rendererHang.isHeld)

        rig.runtime.handle(.renderUnresponsive(browser: 10))
        try #require(tab.state.isUnresponsive)
        rig.window.change(\.isOccluded, true, NSWindow.didChangeOcclusionStateNotification)
        #expect(!tab.state.isUnresponsive, "AppKit's occlusion hides the tab too")
        rig.window.change(\.isOccluded, false, NSWindow.didChangeOcclusionStateNotification)
        #expect(HangReplySpy.replies.map({ $0.terminate }) == [0, 0])
    }

    /// A hidden tab watches no window: its window's notices cost it nothing.
    @Test func onlyAShownTabWatchesItsWindow() throws {
        let rig = try Rig(followsVisibility: true)
        let tab = try rig.shownTab(browser: 10)
        #expect(rig.window.events.subscriberCount(NSWindow.didChangeOcclusionStateNotification) == 1)
        tab.contentDidDisappear()
        #expect(rig.window.events.subscriberCount(NSWindow.didChangeOcclusionStateNotification) == 0)
        tab.contentDidAppear(in: tab.container)
        #expect(rig.window.events.subscriberCount(NSWindow.didChangeOcclusionStateNotification) == 1)
    }

    @Test func waitAndExitPageAnswerTheShownPrompt() throws {
        let rig = try Rig(followsVisibility: true)
        let tab = try rig.shownTab(browser: 10)
        rig.runtime.handle(.renderUnresponsive(browser: 10))

        tab.answerUnresponsivePage(terminate: false)
        #expect(!tab.state.isUnresponsive, "Wait takes the prompt down")
        rig.runtime.handle(.renderUnresponsive(browser: 10))
        tab.answerUnresponsivePage(terminate: true)
        #expect(HangReplySpy.replies.map({ $0.terminate }) == [0, 1])
        #expect(HangReplySpy.replies.allSatisfy({ $0.browser == 10 }), "only that tab's renderer is answered")
    }

    // MARK: Fixtures

    /// A runtime on the spy shim, and pane hosts each showing one tab in one window the test shows or hides.
    @MainActor final class Rig {
        let runtime: CEFRuntime
        let window = ChromiumHostPageVisibilityTests.FakeWindow()

        init(followsVisibility: Bool) throws {
            HangReplySpy.reset()
            let root = FileManager.default.temporaryDirectory.appending(path: "cef-renderer-hang-\(UUID().uuidString)", directoryHint: .isDirectory)
            runtime = CEFRuntime(shim: try HangReplySpy.library(), storage: CEFProfileStorage(root: root))
            runtime.rendererHangFollowsVisibility = followsVisibility
            runtime.rendererHangWindows = window.source
            // A shown tab schedules work that reads its runtime (and its window source) after the test returned.
            _ = Unmanaged.passRetained(runtime)
            _ = Unmanaged.passRetained(window)
        }

        /// A tab whose content view shows in a pane of its own in ``window``, with browser `browser` created.
        func shownTab(browser: Int32) throws -> CEFTab {
            let host = CEFPaneHost(key: CEFPaneKey(pane: BrowserPaneID(rawValue: UUID().uuidString), profile: .default), runtime: runtime)
            host.endOfTurn = { $0() }
            let tab = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
            tab.container.frame = NSRect(x: 0, y: 0, width: 640, height: 480)
            host.add(tab)
            let pending = Set(runtime.pendingWindows.keys)
            window.container.addSubview(tab.container) // its viewDidMoveToWindow calls contentDidAppear(in:)
            host.createDeferred()
            let request = try #require(runtime.pendingWindows.keys.first { !pending.contains($0) })
            runtime.handle(.afterCreated(browser: browser, request: request, window: browser))
            try #require(tab.browserID == browser)
            try #require(tab.showsForRendererHang)
            return tab
        }
    }
}

/// The shim's hang replies, recorded; `cmux_shim_create_window` starts; every other function does nothing.
private nonisolated enum HangReplySpy {
    nonisolated(unsafe) static var replies: [(browser: Int32, terminate: Int32)] = []

    static func reset() {
        replies = []
    }

    static func library() throws -> CEFShimLibrary {
        let createWindow: @convention(c) (Int32, UnsafeMutableRawPointer?, Int32, Int32, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32 = { _, _, _, _, _, _ in 1 }
        let reply: @convention(c) (Int32, Int32) -> Int32 = { browser, terminate in
            HangReplySpy.replies.append((browser, terminate))
            return 1
        }
        let nothing: @convention(c) () -> Int = { 0 }
        return try CEFShimLibrary.resolving { name in
            switch name {
            case "cmux_shim_create_window": unsafeBitCast(createWindow, to: UnsafeMutableRawPointer.self)
            case "cmux_shim_unresponsive_reply": unsafeBitCast(reply, to: UnsafeMutableRawPointer.self)
            default: unsafeBitCast(nothing, to: UnsafeMutableRawPointer.self)
            }
        }
    }
}
