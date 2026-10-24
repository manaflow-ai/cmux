import AppKit
import CmuxNextDesign
import Foundation
import Testing
@testable import CmuxNextAgentPane
import CmuxNextPagesTestSupport

/// Leo 2026-10-14, as the Claude app switches chats: a chat the pane has not drawn yet holds its
/// page background for a beat with no busy mark popping up, then its page fades in (quick but
/// seen); a New Tab page and a chat already drawn show at once.
@Suite(.serialized)
@MainActor
struct AgentPaneColdChatRevealTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    private static func pane(newTab: AgentPaneNewTab? = nil) throws -> (AgentPaneView, NSWindow) {
        _ = NSApplication.shared
        let view = try #require(AgentPaneView(model: AgentPaneModel(host: NoHost(), newTab: newTab),
                                              source: .bundled(URL(filePath: "/dev/null")), errors: DroppedErrors()))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        view.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        window.contentView = view
        window.orderFrontRegardless()
        view.layoutSubtreeIfNeeded()
        return (view, window)
    }

    /// Whether the busy mark draws: in the loading view and not hidden.
    private static func markShows(_ view: AgentPaneView) -> Bool {
        let mark = view.loadingView.indicator
        return mark.superview != nil && !mark.isHidden
    }

    private static func settle(until done: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while !done(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
    }

    @Test func aColdChatHoldsItsBackgroundWithoutAMarkThenFadesIn() async throws {
        let (view, window) = try Self.pane()
        defer { window.close() }
        #expect(view.showsLoadingState, "a chat that has not drawn showed its page's unpainted frames")
        #expect(!Self.markShows(view), "the busy mark popped up the moment the chat was opened")

        view.model.markPainted()
        #expect(view.pageContent.alphaValue == 1, "the page stayed clear under its loading state")
        if Motion.canAnimate(in: view), Motion.home.duration(.fadeIn) > 0 {
            #expect(view.loadingView.superview != nil, "the chat's page replaced its loading state in one frame, with no fade")
        }
        try await Self.settle { view.loadingView.superview == nil }
        #expect(view.loadingView.superview == nil, "the fade never ended")
    }

    @Test func aSlowChatShowsTheMarkAfterABeat() async throws {
        let (view, window) = try Self.pane()
        defer { window.close() }
        try await Self.settle { Self.markShows(view) }
        #expect(Self.markShows(view), "a chat still loading after the beat showed no busy mark")
        view.model.markPainted()
        #expect(!Self.markShows(view), "the busy mark stayed while the page faded in")
    }

    /// cx-txnr: after a relaunch a page that never reported its first paint (WebKit holds an
    /// occluded window's animation frames) kept the pane on its loading state, a spinner over a
    /// clear page, for good. Seen unpainted at two checks in a row, the page counts as painted.
    @Test func aPageThatNeverPaintsDropsItsLoadingStateAtTheDeadline() async throws {
        let (view, window) = try Self.pane()
        defer { window.close() }
        view.loadingView.paintCheckInterval = .milliseconds(100)
        #expect(view.showsLoadingState)
        try await Self.settle { view.loadingView.superview == nil }
        #expect(view.loadingView.superview == nil, "a page that never painted kept its loading state")
        #expect(view.pageContent.alphaValue == 1, "the page stayed clear after the loading state gave up")
        #expect(view.model.hasPainted, "the pane still waits on a paint it gave up on")
    }

    /// A pane out of sight (a New Tab spare parked outside the window's content) keeps its
    /// loading state: its clock runs only while it is seen.
    @Test func aPaneOutOfSightKeepsItsLoadingState() async throws {
        let (view, window) = try Self.pane()
        defer { window.close() }
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        window.contentView = content
        view.frame = NSRect(x: 10_000, y: 10_000, width: 400, height: 300)
        content.addSubview(view)
        view.loadingView.paintCheckInterval = .milliseconds(50)
        try await Task.sleep(for: .milliseconds(400))
        #expect(view.loadingView.superview != nil, "a pane nobody could see gave up on its page")
        #expect(!view.model.hasPainted)
    }

    @Test func aNewTabPageShowsInOneFrame() throws {
        let (view, window) = try Self.pane(newTab: AgentPaneNewTab(kind: .agent))
        defer { window.close() }
        view.model.markPainted()
        #expect(view.loadingView.superview == nil, "a New Tab page faded in")
        #expect(view.pageContent.alphaValue == 1)
    }

    /// A chat the page drew from a kept tail is on screen in the frame the open landed on
    /// (tailCache.ts), so it shows as a New Tab page does: in one frame, with no fade over rows
    /// already drawn. "Instant if cached" (Leo 2026-10-20).
    ///
    /// The decision is what these read (`leftFading`), not what was drawn of it: with motion off —
    /// Reduce Motion, which the CI VMs have on, or a window with no screen — the animation runs its
    /// completion at once, so a fade and no fade both end in one frame. Asserting on the frame
    /// passed with the fix reverted on a headless mini, which is how this file's own gap was found.
    @Test func aChatDrawnFromAKeptTailShowsInOneFrame() async throws {
        let (view, window) = try Self.pane()
        defer { window.close() }
        #expect(view.showsLoadingState)
        _ = await view.model.respond(to: AgentPaneRequest(body: ["method": "pane.painted",
                                                                 "params": ["drewKeptTail": true]]))
        #expect(view.loadingView.leftFading == false, "a chat already on screen was faded in over itself")
        // Where a fade can be seen, the frame says it too. Not the page's alpha: `leave` clears that
        // for a page it is not hidden over, fading or not, so an alpha of 1 here proves nothing.
        if Motion.canAnimate(in: view), Motion.home.duration(.fadeIn) > 0 {
            #expect(view.loadingView.superview == nil, "the chat's page faded in over rows already drawn")
        }
    }

    /// The same report without the fact is a chat read cold, which keeps the fade it had.
    @Test func aChatReadColdStillFadesIn() async throws {
        let (view, window) = try Self.pane()
        defer { window.close() }
        _ = await view.model.respond(to: AgentPaneRequest(body: ["method": "pane.painted"]))
        #expect(view.loadingView.leftFading == true, "a chat read cold showed in one frame, with no fade")
        try await Self.settle { view.loadingView.superview == nil }
        #expect(view.loadingView.superview == nil, "the fade never ended")
    }
}
