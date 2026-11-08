import AppKit
import CmuxHomeCore
@testable import CmuxNextHome
import Foundation
import Testing

/// A queued agent's pill (user 2026-11-07, msg 23835: clicking queued a1034 "failed to open in workspace"): the
/// click opens its chat with where it stands in the queue and Start now, never nothing; once it starts, its tab
/// becomes its real workspace (the session's link opens beside Home and the inline tab closes).
@MainActor @Suite(.serialized) struct HomeQueuedAgentPaneTests {
    typealias Threads = HomeAgentPaneTests.Threads

    static let start = Date(timeIntervalSince1970: 1_000)

    static func queued(_ peer: String, title: String) -> HomeAgentThread {
        HomeAgentThread(peer: peer, title: title, state: .queued, task: "Title: \(title)\n\nBuild it.", entries: [],
                        startedAt: start, endedAt: nil, newestReportAt: nil, workspaceLink: nil)
    }

    @Test func aQueuedAgentsPillOpensItsChatWithItsPlaceInLineAndStartNow() async throws {
        let threads = Threads()
        threads.threads = ["a7": Self.queued("a7", title: "Custom sidebar")]
        threads.queued = ["a5", "a6", "a7"]
        let pane = HomeAgentPane(conversation: ConversationID("c"), threads: threads)
        var opened: [URL] = []
        // No link yet: it opens here, and never silently fails.
        #expect(!pane.open("a7", outside: { opened.append($0); return true }))
        #expect(opened.isEmpty && pane.tabs == ["a7"] && pane.selected == "a7")
        let content = try #require(pane.content("a7", now: Self.start.addingTimeInterval(57)))
        #expect(content.isQueued)
        #expect(content.ahead == 2)
        #expect(content.queueLine == "2 ahead of it")

        var started: [String] = []
        let view = HomeAgentPaneView(pane: pane)
        defer { view.stop() }
        view.onStartAgent = { peer in started.append(peer); return true }
        view.apply()
        let chat = try #require(view.selectedChat)
        let button = try #require(chat.startNowButton)
        #expect(chat.goToWorkspaceButton == nil)
        button.performClick(nil)
        await view.pendingStart?.value
        #expect(started == ["a7"])
        // While the Chief starts it, the button says so and takes no second click.
        view.apply()
        #expect(view.selectedChat?.startNowButton?.isEnabled == false)
    }

    @Test func theNextOneInLineSaysItStartsNext() throws {
        let threads = Threads()
        threads.threads = ["a5": Self.queued("a5", title: "First")]
        threads.queued = ["a5", "a6"]
        let pane = HomeAgentPane(conversation: ConversationID("c"), threads: threads)
        pane.open("a5")
        let content = try #require(pane.content("a5", now: Self.start))
        #expect(content.ahead == 0)
        #expect(content.queueLine == "Starts next")
    }

    @Test func aQueuedAgentThatStartsBecomesItsWorkspace() throws {
        let threads = Threads()
        threads.threads = ["a7": Self.queued("a7", title: "Custom sidebar")]
        threads.queued = ["a7"]
        let pane = HomeAgentPane(conversation: ConversationID("c"), threads: threads)
        let view = HomeAgentPaneView(pane: pane)
        defer { view.stop() }
        var opened: [URL] = []
        view.onHandOff = { opened.append($0); return true }
        pane.open("a7")
        view.apply()
        #expect(opened.isEmpty && pane.tabs == ["a7"])

        // A slot freed: its session showed (the store says Working) and it has a place to open.
        var running = Self.queued("a7", title: "Custom sidebar")
        running.state = .told
        threads.threads["a7"] = running
        threads.queued = []
        threads.sessions["a7"] = HomeAgentSessionRef(peer: "a7", session: "optchat-sub-0123abcd-a7")
        view.apply()
        #expect(opened == [try #require(URL(string: "cmux://session/optchat-sub-0123abcd-a7"))])
        #expect(pane.tabs.isEmpty && !pane.isShown)
    }

    @Test func anAgentOpenedAfterItStartedIsNotHandedOffAgain() {
        let threads = Threads()
        var running = Self.queued("a7", title: "Custom sidebar")
        running.state = .told
        threads.threads = ["a7": running]
        let pane = HomeAgentPane(conversation: ConversationID("c"), threads: threads)
        let view = HomeAgentPaneView(pane: pane)
        defer { view.stop() }
        var opened: [URL] = []
        view.onHandOff = { opened.append($0); return true }
        pane.open("a7")
        view.apply()
        // Only an agent opened while queued moves on its own; a working one stays where the person put it.
        #expect(opened.isEmpty && pane.tabs == ["a7"])
    }
}
