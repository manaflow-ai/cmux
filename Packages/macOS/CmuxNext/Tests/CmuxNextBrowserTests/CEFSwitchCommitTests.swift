import AppKit
@testable import CmuxNextBrowser
import Testing

/// A hosted page shows and hides in the switch's own transaction. The switch's turn
/// only shows or hides the view (the page's layer goes with it); the fork hears the page's visibility,
/// the shown tab's activation and the input window's place once, after that commit. A hidden page's
/// frame goes when the fork takes the hide. Without Chromium: a fake fork, and the end of the turn and
/// the commit run when the test says.
@MainActor
@Suite struct CEFSwitchCommitTests {
    /// The fork side: every call in order, as `name browser`.
    final class FakeFork {
        private(set) var calls: [String] = []
        /// The embedder visibility the fork keeps per page window, across hosting off and on (058's header).
        private(set) var stored: [Int32: CEFLayerHosting.PageVisibility] = [:]
        var acceptsVisibility = true
        var hasVisibility = true
        var syncs: [Int32] = []
        func clear() { calls = [] }
        var fork: CEFLayerHosting.Fork {
            var setVisibility: ((Int32, CEFLayerHosting.PageVisibility) -> Bool)?
            if hasVisibility {
                setVisibility = { [self] browser, visibility in
                    calls.append("visibility \(browser) \(visibility)")
                    if acceptsVisibility { stored[browser] = visibility }
                    return acceptsVisibility
                }
            }
            return CEFLayerHosting.Fork(
                setLayerHosting: { [self] browser, enabled in
                    calls.append("hosting \(browser) \(enabled)")
                    return enabled ? 7 : 0
                },
                setResizeSync: { [self] _, timeout in
                    syncs.append(timeout)
                    return true
                },
                setVisibility: setVisibility,
                evictFrame: { [self] browser in
                    calls.append("evict \(browser)")
                    return true
                })
        }
    }

    let fake = FakeFork()
    let turn = CEFLayerHostingTests.Turn()
    let commit = CEFLayerHostingTests.Turn()
    let view = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
    let window: NSWindow

    init() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: .borderless,
                          backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        window.contentView?.addSubview(view)
    }

    /// A hosted page window for browser 3, every creation step run (the first pass made it visible), its
    /// calls cleared.
    func makeHostedPage(isEnabled: @escaping () -> Bool = { true }) -> CEFLayerHosting {
        let turn = turn, commit = commit
        let hosting = CEFLayerHosting(isEnabled: isEnabled, schedule: { turn.add($0) },
                                      makePage: { ChromiumHostPageView(frame: $0, inputTarget: .pageWindow, makeLayerHost: { _ in CALayer() }) },
                                      resizeDeadlineMs: { 8 }, refreshIntervals: { [] },
                                      afterCommit: { commit.add($0) })
        hosting.view = view
        hosting.pageWindowCreated(browser: 3, fork: fake.fork)
        turn.end()
        commit.end()
        fake.clear()
        return hosting
    }

    /// The fork's default lets the page window's order decide, and a hosted page window never orders in:
    /// the first pass after hosting tells the fork the page shows.
    @Test func aNewlyHostedPageIsMadeVisibleAfterTheCommit() {
        let turn = turn, commit = commit
        let hosting = CEFLayerHosting(isEnabled: { true }, schedule: { turn.add($0) },
                                      makePage: { ChromiumHostPageView(frame: $0, inputTarget: .pageWindow, makeLayerHost: { _ in CALayer() }) },
                                      resizeDeadlineMs: { 8 }, refreshIntervals: { [] },
                                      afterCommit: { commit.add($0) })
        hosting.view = view
        #expect(hosting.switchCommit.applied == .window)
        hosting.pageWindowCreated(browser: 3, fork: fake.fork)
        turn.end()
        #expect(fake.calls == ["hosting 3 true"])
        commit.end()
        #expect(fake.calls == ["hosting 3 true", "visibility 3 visible"])
        #expect(hosting.switchCommit.applied == .visible)
    }

    @Test func aWorkspaceSwitchMakesNoForkCallInItsTurnAndOneAfterTheCommit() {
        let hosting = makeHostedPage()
        let before = hosting.switchCommit.forkCalls
        #expect(hosting.showsInSwitchTransaction)
        // Switch away: the content lifecycle hides the page's view; its layer leaves with it in this transaction.
        view.isHidden = true
        hosting.visibilityMayHaveChanged()
        turn.end()
        #expect(fake.calls.isEmpty, "no fork call in the switch's turn")
        commit.end()
        #expect(fake.calls == ["visibility 3 hidden", "evict 3"])
        // Switch back: shown in the switch's frame, the fork told after the commit.
        fake.clear()
        view.isHidden = false
        hosting.visibilityMayHaveChanged()
        #expect(fake.calls.isEmpty)
        commit.end()
        #expect(fake.calls == ["visibility 3 visible"])
        #expect(hosting.switchCommit.forkCalls == before + 3)
    }

    @Test func aTurnThatHidesAndShowsThePageAgainMakesNoCall() {
        let hosting = makeHostedPage()
        view.isHidden = true
        hosting.visibilityMayHaveChanged()
        view.isHidden = false
        hosting.visibilityMayHaveChanged()
        commit.end()
        #expect(fake.calls.isEmpty)
        #expect(commit.isEmpty)
    }

    @Test func aViewOutOfEveryWindowIsHidden() {
        let hosting = makeHostedPage()
        view.removeFromSuperview()
        hosting.windowDidChange()
        commit.end()
        #expect(fake.calls == ["visibility 3 hidden", "evict 3"])
    }

    /// A tab switch in a hosted pane: the activation waits for the commit, the last show of the turn
    /// wins, and the input window is placed after the page's visibility.
    @Test func aTabSwitchActivatesAfterTheCommitAndTheLastShowWins() {
        let hosting = makeHostedPage()
        var log: [String] = []
        hosting.pageShown(browser: 4)
        hosting.showAfterCommit(activate: { log.append("activate 4") }, place: { log.append("place 4") })
        hosting.pageShown(browser: 5)
        hosting.showAfterCommit(activate: { log.append("activate 5") }, place: { log.append("place 5") })
        #expect(log.isEmpty)
        #expect(fake.calls.isEmpty)
        commit.end()
        #expect(log == ["activate 5", "place 5"])
        #expect(fake.calls.isEmpty, "a tab switch in a shown pane changes no page window visibility")
    }

    @Test func aShowIntoAHiddenPaneActivatesBeforeThePageShows() {
        let hosting = makeHostedPage()
        view.isHidden = true
        hosting.visibilityMayHaveChanged()
        commit.end()
        fake.clear()
        var log: [String] = []
        view.isHidden = false
        hosting.visibilityMayHaveChanged()
        hosting.showAfterCommit(activate: { log.append("activate \(fake.calls.count)") }, place: { log.append("place \(fake.calls.count)") })
        commit.end()
        // The new tab becomes active while the window is hidden, so only it is shown to Chromium.
        #expect(log == ["activate 0", "place 1"])
        #expect(fake.calls == ["visibility 3 visible"])
    }

    @Test func aChangedResizeDeadlineReachesTheForkAfterTheCommit() {
        var deadline: Int32 = 8
        let turn = turn, commit = commit
        let hosting = CEFLayerHosting(isEnabled: { true }, schedule: { turn.add($0) },
                                      makePage: { ChromiumHostPageView(frame: $0, inputTarget: .pageWindow, makeLayerHost: { _ in CALayer() }) },
                                      resizeDeadlineMs: { deadline }, refreshIntervals: { [] },
                                      afterCommit: { commit.add($0) })
        hosting.view = view
        hosting.pageWindowCreated(browser: 3, fork: fake.fork)
        turn.end()
        commit.end()
        let before = fake.syncs.count
        deadline = 4
        hosting.pageShown(browser: 3)
        #expect(fake.syncs.count == before)
        commit.end()
        #expect(fake.syncs.last == 4)
    }

    @Test func withoutTheForksVisibilityCallTheShowStaysInTheTurn() {
        fake.hasVisibility = false
        let hosting = makeHostedPage()
        #expect(!hosting.showsInSwitchTransaction)
        view.isHidden = true
        hosting.visibilityMayHaveChanged()
        #expect(commit.isEmpty)
        #expect(hosting.switchCommit.forkCalls == 0)
    }

    @Test func aRefusedVisibilityIsTriedAgainAtTheNextPass() {
        let hosting = makeHostedPage()
        fake.acceptsVisibility = false
        view.isHidden = true
        hosting.visibilityMayHaveChanged()
        commit.end()
        #expect(hosting.switchCommit.applied == .visible)
        fake.acceptsVisibility = true
        hosting.visibilityMayHaveChanged()
        commit.end()
        #expect(fake.calls == ["visibility 3 hidden", "visibility 3 hidden", "evict 3"])
        #expect(hosting.switchCommit.applied == .hidden)
    }

    @Test func aHiddenPagesFrameGoesAtOnceAndAShowMakesNoEviction() {
        let hosting = makeHostedPage()
        view.isHidden = true
        hosting.visibilityMayHaveChanged()
        commit.end()
        #expect(fake.calls == ["visibility 3 hidden", "evict 3"])
        #expect(hosting.switchCommit.isPastGrace)
        view.isHidden = false
        hosting.visibilityMayHaveChanged()
        commit.end()
        #expect(fake.calls == ["visibility 3 hidden", "evict 3", "visibility 3 visible"])
        #expect(!hosting.switchCommit.isPastGrace)
    }

    @Test func aPageThatStopsBeingHostedGoesBackToItsWindowsOrder() {
        let hosting = makeHostedPage()
        view.isHidden = true
        hosting.visibilityMayHaveChanged()
        commit.end()
        hosting.stop()
        #expect(fake.calls == ["visibility 3 hidden", "evict 3", "hosting 3 false", "visibility 3 window"],
                "the fork keeps a value across hosting off and on, so the page window's order decides again")
        #expect(hosting.switchCommit.applied == .window)
    }

    /// The fork keeps the embedder visibility across hosting off and on: a page hidden, un-hosted, hosted
    /// again and shown must not keep the hidden value it had before.
    @Test func aPageHiddenThenUnhostedShowsWhenItIsHostedAgain() {
        final class Switch { var on = true }
        let hostingOn = Switch()
        let hosting = makeHostedPage(isEnabled: { hostingOn.on })
        view.isHidden = true
        hosting.visibilityMayHaveChanged()
        commit.end()
        #expect(fake.stored[3] == .hidden)
        hostingOn.on = false
        hosting.pageShown(browser: 3)
        #expect(hosting.page == nil)
        #expect(fake.stored[3] == .window)
        hostingOn.on = true
        view.isHidden = false
        hosting.pageShown(browser: 3)
        commit.end()
        #expect(fake.calls == ["visibility 3 hidden", "evict 3", "hosting 3 false", "visibility 3 window",
                               "hosting 3 true", "visibility 3 visible"])
        #expect(fake.stored[3] == .visible)
        #expect(hosting.switchCommit.applied == .visible)
    }

    /// A page window that never had a value from the app makes no call when it stops being hosted.
    @Test func aPageThatNeverTookAValueMakesNoCallWhenItStops() {
        fake.acceptsVisibility = false
        let hosting = makeHostedPage()
        hosting.stop()
        #expect(fake.calls == ["hosting 3 false"])
    }
}

/// The shim side of the page window's visibility (p03-rendering-058's `cmux_shim_browser_set_embedder_visibility`):
/// the integers the shim receives are its `cmux_shim_embedder_visibility_t`, and the call is made only from fork
/// API 34 on a shim with the export.
@MainActor
@Suite(.serialized) struct CEFEmbedderVisibilityShimTests {
    @Test func theShimReceivesTheHeadersValueForEachVisibility() throws {
        VisibilitySpy.reset()
        let shim = try CEFShimLibrary.resolving(VisibilitySpy.symbol)
        let fork = try #require(CEFLayerHosting.Fork(shim: shim, apiVersion: CEFLayerHosting.embedderVisibilityForkAPI,
                                                     policy: CEFLayerHosting.Policy(trackA: [.resizeFence])))
        let setVisibility = try #require(fork.setVisibility)
        let all: [CEFLayerHosting.PageVisibility] = [.window, .visible, .occluded, .hidden]
        for visibility in all { #expect(setVisibility(3, visibility)) }
        // CMUX_SHIM_EMBEDDER_VISIBILITY_WINDOW, _VISIBLE, _OCCLUDED, _HIDDEN.
        #expect(VisibilitySpy.calls.map(\.visibility) == [0, 1, 2, 3])
        #expect(VisibilitySpy.calls.allSatisfy { $0.browser == 3 })
        #expect(fork.trackA == .required, "the app makes the embedder visibility call for this fork")
    }

    @Test func belowForkAPI34OrWithoutTheExportTheAppMakesNoVisibilityCall() throws {
        VisibilitySpy.reset()
        let shim = try CEFShimLibrary.resolving(VisibilitySpy.symbol)
        let older = try #require(CEFLayerHosting.Fork(shim: shim, apiVersion: CEFLayerHosting.embedderVisibilityForkAPI - 1,
                                                      policy: CEFLayerHosting.Policy(trackA: [.resizeFence])))
        #expect(older.setVisibility == nil)
        #expect(older.trackA == [.resizeFence])
        VisibilitySpy.hasExport = false
        let noExport = try CEFShimLibrary.resolving(VisibilitySpy.symbol)
        let fork = try #require(CEFLayerHosting.Fork(shim: noExport, apiVersion: CEFLayerHosting.embedderVisibilityForkAPI))
        #expect(fork.setVisibility == nil)
        #expect(fork.trackA == nil, "the feature off stays off")
        #expect(VisibilitySpy.calls.isEmpty)
    }
}

/// Stand-in shim functions: `browser_set_embedder_visibility` records each call and takes it (when
/// `hasExport`); every other function does nothing and returns 0.
private nonisolated enum VisibilitySpy {
    nonisolated(unsafe) static var calls: [(browser: Int32, visibility: Int32)] = []
    nonisolated(unsafe) static var hasExport = true

    static func reset() {
        calls = []
        hasExport = true
    }

    static func symbol(_ name: String) -> UnsafeMutableRawPointer? {
        let embedderVisibility: @convention(c) (Int32, Int32) -> Int32 = { browser, visibility in
            VisibilitySpy.calls.append((browser, visibility))
            return 1
        }
        let nothing: @convention(c) () -> Int = { 0 }
        if name == "cmux_shim_browser_set_embedder_visibility" {
            return hasExport ? unsafeBitCast(embedderVisibility, to: UnsafeMutableRawPointer.self) : nil
        }
        return unsafeBitCast(nothing, to: UnsafeMutableRawPointer.self)
    }
}
