import AppKit
import CmuxNextDesign
import CmuxNextTestSupport
import Foundation
import Testing
@testable import CmuxNextAgentPane

/// Leo 2026-10-14, as the Claude app switches chats: a chat the pane has not drawn yet holds its
/// page background for a beat with no busy mark popping up, then its page fades in (quick but
/// seen); a New Tab page and a chat already drawn show at once.
@Suite(.serialized, .closesItsWindows)
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

    /// How long a wait here may take before it reports. Not a timing these tests check: each wait
    /// ends on its condition, and in the full parallel CmuxNextAppTests run a starved main actor
    /// (tests there report 100 to 500 s) held a 120 ms fade's completion past the 2 s this was.
    /// It only keeps a condition that never comes from holding the run.
    private static let hangBound: Duration = .seconds(60)

    private static func settle(until done: () -> Bool) async throws {
        let deadline = ContinuousClock.now + hangBound
        while !done(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
    }

    /// Waits for the loading state to leave the pane: the fade's own completion
    /// (``AgentPaneLoadingView/whenRevealed(_:)``), or at once when it shows in one frame. False
    /// when it has not left by ``hangBound``.
    private static func revealed(_ view: AgentPaneView) async -> Bool {
        let once = Once()
        return await withCheckedContinuation { continuation in
            once.continuation = continuation
            // Armed before the reveal can answer, so its answer cancels it; it stops either way.
            once.deadline = Task { @MainActor in
                try? await Task.sleep(for: hangBound)
                once.finish(false)
            }
            view.loadingView.whenRevealed { once.finish(true) }
        }
    }

    /// One answer for `revealed`: the reveal or the bound, whichever comes first; the other does nothing.
    @MainActor private final class Once {
        var continuation: CheckedContinuation<Bool, Never>?
        var deadline: Task<Void, Never>?

        func finish(_ value: Bool) {
            guard let continuation else { return }
            self.continuation = nil
            deadline?.cancel()
            continuation.resume(returning: value)
        }
    }

    @Test func aColdChatLoadingCoverHasNoTranscriptSkeleton() throws {
        let (view, window) = try Self.pane()
        defer { window.close() }

        // The loading cover is deliberately just the pane background and its delayed busy mark.
        // Transcript-shaped bars are a skeleton and must never return to the chat-open path.
        #expect(view.loadingView.subviews.allSatisfy { $0 === view.loadingView.indicator },
                "a cold chat loading cover drew a transcript skeleton")
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
        #expect(await Self.revealed(view))
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
        #expect(await Self.revealed(view))
        #expect(view.loadingView.superview == nil, "a page that never painted kept its loading state")
        #expect(view.pageContent.alphaValue == 1, "the page stayed clear after the loading state gave up")
        #expect(view.model.hasPainted, "the pane still waits on a paint it gave up on")
    }

    /// Leo 2026-10-22: "the initial load is kinda slow it like flickers the initial thing/paints
    /// and renders it... and then it just goes to black screen for a while". A page that answered
    /// the handshake is not the stuck page this give-up is for: it is waiting on its own chat and
    /// reports its first paint by `CHAT_DRAW_HOLD_MS` either way. Revealing it at the silent bound
    /// showed that black screen, so it keeps its loading state past that bound.
    ///
    /// `aHandshakedPageStillShowsAsItIsAtItsOwnBound` is the canary for this one: both drive the
    /// same timer, so a host where no check ran at all fails there rather than passing here.
    @Test func aHandshakedPageKeepsItsLoadingStatePastTheSilentBound() async throws {
        let (view, window) = try Self.pane()
        defer { window.close() }
        view.model.hasHandshake = true
        let tick = Duration.milliseconds(120)
        view.loadingView.paintCheckInterval = tick
        // Past the silent bound with a check to spare, short of the handshaked page's own bound.
        try await Task.sleep(for: tick * 3)
        #expect(view.loadingView.superview != nil,
                "the pane revealed a page that was still inside its own first-paint budget")
        #expect(!view.model.hasPainted)
    }

    /// The longer bound is still a bound: a page that answers the handshake and then hangs shows
    /// as it is too, rather than holding a spinner for good.
    @Test func aHandshakedPageStillShowsAsItIsAtItsOwnBound() async throws {
        let (view, window) = try Self.pane()
        defer { window.close() }
        view.model.hasHandshake = true
        view.loadingView.paintCheckInterval = .milliseconds(60)
        #expect(await Self.revealed(view))
        #expect(view.loadingView.superview == nil, "a handshaked page that never painted waited for good")
        #expect(view.model.hasPainted)
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
        #expect(await Self.revealed(view))
        #expect(view.loadingView.superview == nil, "the fade never ended")
    }
}
