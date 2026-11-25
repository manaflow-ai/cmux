import AppKit
import CmuxNextTestSupport
import Foundation
import Testing
@testable import CmuxNextAgentPane

/// cmux#48605: a chat that took long to open showed a blank pane, sometimes with the busy mark and sometimes
/// without, because a chat this app showed in the last hour opened with no mark however long its page took (a
/// hidden chat released under memory pressure and built again, a page Chromium dropped and WebKit reopened).
/// Every chat still loading past the beat now shows the mark; one that paints within the beat shows none.
@Suite(.serialized, .closesItsWindows)
@MainActor
struct AgentPaneLoadingMarkTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    private static func pane(session: String?) throws -> (AgentPaneView, NSWindow) {
        _ = NSApplication.shared
        let view = try #require(AgentPaneView(model: AgentPaneModel(host: NoHost(), sessionId: session),
                                              source: .bundled(URL(filePath: "/dev/null"))))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        view.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        window.contentView = view
        window.orderFrontRegardless()
        view.layoutSubtreeIfNeeded()
        // The give-up never ends the cover inside these tests.
        view.loadingView.paintCheckInterval = .seconds(120)
        return (view, window)
    }

    private static func markShows(_ view: AgentPaneView) -> Bool {
        let mark = view.loadingView.indicator
        return mark.superview != nil && !mark.isHidden
    }

    /// Holds the pane unpainted past the mark's delay, as a page slower than the beat does, sampling every 10 ms
    /// whether the busy mark drew; then the page paints. True when any sample saw the mark.
    private static func slowOpenShowsMark(_ view: AgentPaneView) async throws -> Bool {
        var sawMark = false
        let end = ContinuousClock.now + AgentPaneLoadingView.markDelay + .milliseconds(300)
        while ContinuousClock.now < end {
            if markShows(view) { sawMark = true }
            try await Task.sleep(for: .milliseconds(10))
        }
        view.model.markPainted()
        return sawMark
    }

    /// Shows chat `session` once, as the person saw it: its page painted.
    private static func showOnce(_ session: String) throws {
        let (view, window) = try pane(session: session)
        view.model.markPainted()
        window.close()
    }

    @Test func aChatShownBeforeStillShowsTheBusyMarkWhenItsPageIsSlow() async throws {
        let session = "seen-\(UUID().uuidString)"
        try Self.showOnce(session)
        var rounds = 0
        var markRounds = 0
        // Ten switches back to the chat, each a new page (a released chat built again) slower than the beat.
        for _ in 0..<10 {
            let (view, window) = try Self.pane(session: session)
            defer { window.close() }
            #expect(view.showsLoadingState, "fixture: the rebuilt chat's cover is up")
            rounds += 1
            if try await Self.slowOpenShowsMark(view) { markRounds += 1 }
        }
        print("loading-mark: switches=\(rounds) switches_with_busy_mark=\(markRounds)")
        #expect(markRounds == rounds, "a chat shown before and still loading past the beat showed a blank pane on \(rounds - markRounds) of \(rounds) switches")
    }

    @Test func aChatNeverShownStillGetsTheMarkAfterTheBeat() async throws {
        let (view, window) = try Self.pane(session: "never-\(UUID().uuidString)")
        defer { window.close() }
        #expect(try await Self.slowOpenShowsMark(view), "a chat never shown and still loading after the beat showed no busy mark")
    }

    @Test func aPageThatPaintsWithinTheBeatShowsNoMark() async throws {
        let (view, window) = try Self.pane(session: "quick-\(UUID().uuidString)")
        defer { window.close() }
        try await Task.sleep(for: AgentPaneLoadingView.markDelay / 3)
        #expect(!Self.markShows(view), "the mark drew before the beat")
        view.model.markPainted()
        try await Task.sleep(for: AgentPaneLoadingView.markDelay)
        #expect(!Self.markShows(view), "a page that painted within the beat still drew the busy mark")
    }
}
