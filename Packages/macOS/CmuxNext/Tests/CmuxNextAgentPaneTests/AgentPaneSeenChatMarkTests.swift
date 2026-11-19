import AppKit
import CmuxNextTestSupport
import Foundation
import Testing
@testable import CmuxNextAgentPane

/// Leo, 2026-11-18: "we shouldnt need to see spinners on loading switching between chats most of the time".
/// A chat this app already showed (a released hidden chat built again, a sidebar open of a chat read before) is
/// one the person knows and whose copy the page draws first; its pane's loading cover never shows the busy mark,
/// however long its page takes. A chat never shown in this app's life still gets the mark after the beat.
@Suite(.serialized, .closesItsWindows)
@MainActor
struct AgentPaneSeenChatMarkTests {
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

    @Test func aChatShownBeforeOpensWithNoBusyMarkEvenWhenItsPageIsSlow() async throws {
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
        print("seen-chat-mark: switches=\(rounds) switches_with_busy_mark=\(markRounds)")
        #expect(markRounds == 0, "switching back to a chat this app showed drew the busy mark on \(markRounds) of \(rounds) switches")
    }

    @Test func aChatNeverShownStillGetsTheMarkAfterTheBeat() async throws {
        let (view, window) = try Self.pane(session: "never-\(UUID().uuidString)")
        defer { window.close() }
        #expect(try await Self.slowOpenShowsMark(view), "a chat never shown and still loading after the beat showed no busy mark")
    }

    @Test func seenChatsAreBoundedByCountAndAge() {
        var now = ContinuousClock.now
        let seen = AgentPaneSeenChats(limit: 3, window: .seconds(3_600), clock: { now })
        for name in ["a", "b", "c", "d"] { seen.noteShown(name) }
        #expect(!seen.wasShown("a"), "a chat past the count bound still counted as shown")
        #expect(seen.wasShown("b") && seen.wasShown("d"))
        #expect(seen.count == 3, "the store grew past its bound")
        now += .seconds(3_601)
        #expect(!seen.wasShown("d"), "a chat shown over an hour ago still counted as shown")
        seen.noteShown("e")
        #expect(seen.count == 1, "chats past the window stayed in the store")
    }
}
