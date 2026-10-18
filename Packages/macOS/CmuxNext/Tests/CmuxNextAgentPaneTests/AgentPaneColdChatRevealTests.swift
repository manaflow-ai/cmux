import AppKit
import CmuxNextDesign
import Foundation
import Testing
@testable import CmuxNextAgentPane

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
                                              source: .bundled(URL(filePath: "/dev/null"))))
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
        if Motion.canAnimate(in: view), Motion.duration(.fadeIn) > 0 {
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
    /// clear page, for good. The loading state gives up at its deadline and shows the page.
    @Test func aPageThatNeverPaintsDropsItsLoadingStateAtTheDeadline() async throws {
        let limit = AgentPaneLoadingView.paintLimit
        AgentPaneLoadingView.paintLimit = .milliseconds(200)
        defer { AgentPaneLoadingView.paintLimit = limit }
        let (view, window) = try Self.pane()
        defer { window.close() }
        #expect(view.showsLoadingState)
        try await Self.settle { view.loadingView.superview == nil }
        #expect(view.loadingView.superview == nil, "a page that never painted kept its loading state")
        #expect(view.pageContent.alphaValue == 1, "the page stayed clear after the loading state gave up")
        #expect(!view.model.hasPainted)

        view.model.markPainted()
        #expect(view.loadingView.superview == nil, "a late paint brought the loading state back")
        #expect(view.pageContent.alphaValue == 1)
    }

    @Test func aNewTabPageShowsInOneFrame() throws {
        let (view, window) = try Self.pane(newTab: AgentPaneNewTab(kind: .agent))
        defer { window.close() }
        view.model.markPainted()
        #expect(view.loadingView.superview == nil, "a New Tab page faded in")
        #expect(view.pageContent.alphaValue == 1)
    }
}
