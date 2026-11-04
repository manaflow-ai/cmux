import AppKit
import CmuxHomeCore
@testable import CmuxNextHome
import Foundation
import Testing

/// The agent pane (user 2026-11-03, msg 19960): a click on a pill opens that agent's chat in a tab, one tab per
/// agent; opening it marks its report seen (the unread dot clears); the chat starts with "Sent via Chief" over
/// the task (Show more), then "Worked for 5m 35s ›", then the later messages; Go to workspace shows only when
/// the Chief linked the agent's session, and opens that link.
@MainActor @Suite(.serialized) struct HomeAgentPaneTests {
    /// The store's two calls, recorded.
    final class Threads: HomeAgentThreadReading {
        var threads: [String: HomeAgentThread] = [:]
        var seen: [String] = []
        var sent: [String] = []
        func agentThread(_ peer: String, in conversation: ConversationID) -> HomeAgentThread? { threads[peer] }
        func markAgentSeen(_ peer: String, in conversation: ConversationID) { seen.append(peer) }
        func sendToAgent(_ text: String, peer: String, in conversation: ConversationID) { sent.append("\(peer): \(text)") }
    }

    static let start = Date(timeIntervalSince1970: 1_000)

    static func thread(_ peer: String, title: String, link: URL? = nil) -> HomeAgentThread {
        HomeAgentThread(
            peer: peer, title: title, state: .reported,
            task: "Title: \(title)\n\n" + String(repeating: "Measure both rows at 100% and 200%, light and dark. ", count: 20),
            entries: [.init(id: "t2", outgoing: true, text: "Also add a test.", date: start.addingTimeInterval(60)),
                      .init(id: "r1", outgoing: false, text: "Done: landed.", date: start.addingTimeInterval(335))],
            startedAt: start, endedAt: start.addingTimeInterval(335), newestReportAt: start.addingTimeInterval(335), workspaceLink: link)
    }

    @Test func aPillOpensOneTabPerAgentAndMarksItSeen() {
        let threads = Threads()
        let pane = HomeAgentPane(conversation: ConversationID("c"), threads: threads)
        #expect(!pane.isShown)
        pane.open("a1")
        pane.open("a2")
        #expect(pane.tabs == ["a1", "a2"] && pane.selected == "a2")
        // A second click on a1's pill selects its tab; no second tab.
        pane.open("a1")
        #expect(pane.tabs == ["a1", "a2"] && pane.selected == "a1")
        #expect(threads.seen == ["a1", "a2", "a1"])
        pane.close("a1")
        #expect(pane.tabs == ["a2"] && pane.selected == "a2")
        pane.close("a2")
        #expect(!pane.isShown && pane.selected == nil)
    }

    @Test func theChatStartsWithTheTaskSentViaChiefThenHowLongItWorked() {
        let content = HomeAgentChatContent(Self.thread("a1", title: "Fix the sidebar"), now: .distantFuture)
        #expect(content.title == "Fix the sidebar")
        #expect(content.task.hasPrefix("Title: Fix the sidebar"))
        #expect(content.workedFor.contains(HomeAgentChatContent.duration(335)))
        #expect(content.workedFor != HomeAgentChatContent.duration(335))
        #expect(content.messages == [.init(sender: .chief, text: "Also add a test."), .init(sender: .agent, text: "Done: landed.")])
        #expect(content.details.count == 2)
        #expect(content.workspaceLink == nil)
    }

    @Test func showMoreShowsTheWholeTask() throws {
        let chat = HomeAgentChatView(content: HomeAgentChatContent(Self.thread("a1", title: "Fix"), now: .distantFuture),
                                     actions: .init())
        #expect(!chat.isTaskExpanded)
        chat.toggleTask(NSButton())
        #expect(chat.isTaskExpanded)
        chat.toggleTask(NSButton())
        #expect(!chat.isTaskExpanded)
    }

    @Test func goToWorkspaceShowsOnlyForALinkedAgentAndOpensItsLink() throws {
        let link = try #require(URL(string: "cmux://chief/0123abcd/session/s-81"))
        let threads = Threads()
        threads.threads = ["a1": Self.thread("a1", title: "Linked", link: link), "a2": Self.thread("a2", title: "Not linked")]
        let pane = HomeAgentPane(conversation: ConversationID("c"), threads: threads)
        let view = HomeAgentPaneView(pane: pane)
        defer { view.stop() }
        view.frame = NSRect(x: 0, y: 0, width: 420, height: 600)
        var opened: [URL] = []
        view.onGoToWorkspace = { opened.append($0) }
        pane.open("a1")
        view.apply()
        #expect(view.side.peers == ["a1"])
        let go = try #require(view.selectedChat?.goToWorkspaceButton)
        go.performClick(nil)
        #expect(opened == [link])
        pane.open("a2")
        view.apply()
        #expect(view.side.peers == ["a1", "a2"])
        #expect(view.selectedChat?.content.title == "Not linked")
        #expect(view.selectedChat?.goToWorkspaceButton == nil)
        // Closing a tab from the pane takes it out of the strip.
        pane.close("a1")
        view.apply()
        #expect(view.side.peers == ["a2"])
    }

    // MARK: Slice 3: the shared composer and its sender labels (user 2026-11-03, msgs 19960/19968)

    @Test func everyMessageToTheAgentSaysWhoSentIt() {
        var thread = Self.thread("a1", title: "Fix")
        thread.entries = [
            .init(id: "n1", outgoing: true, text: "Use the 2x shot.", date: Self.start.addingTimeInterval(30), sender: .you),
            .init(id: "t2", outgoing: true, text: "Also add a test.", date: Self.start.addingTimeInterval(60), sender: .chief),
            .init(id: "r1", outgoing: false, text: "Done: landed.", date: Self.start.addingTimeInterval(335)),
        ]
        let content = HomeAgentChatContent(thread, now: .distantFuture)
        #expect(content.messages == [.init(sender: .you, text: "Use the 2x shot."), .init(sender: .chief, text: "Also add a test."),
                                     .init(sender: .agent, text: "Done: landed.")])
        #expect(content.messages.map(\.sender.label) == [HomeAgentChatContent.Sender.you.label, HomeAgentChatContent.Sender.chief.label, nil])
    }

    @Test func theShippedPaneHasTheComposerAndItsMessageGoesToTheAgentThroughTheChief() throws {
        let threads = Threads()
        threads.threads = ["a1": Self.thread("a1", title: "Fix")]
        let pane = HomeAgentPane(conversation: ConversationID("c"), threads: threads)
        let view = HomeAgentPaneView(pane: pane)
        defer { view.stop() }
        view.frame = NSRect(x: 0, y: 0, width: 420, height: 600)
        pane.open("a1")
        view.apply()
        let chat = try #require(view.selectedChat)
        #expect(chat.hasComposer)
        chat.sendFromComposer("Use the 2x shot.")
        #expect(threads.sent == ["a1: Use the 2x shot."])
        // A new message in the agent's chat redraws it in place: the composer the person types in stays.
        var newer = Self.thread("a1", title: "Fix")
        newer.entries.append(.init(id: "n1", outgoing: true, text: "Use the 2x shot.", date: Self.start.addingTimeInterval(400), sender: .you))
        threads.threads["a1"] = newer
        view.apply()
        #expect(view.selectedChat === chat)
        #expect(chat.content.messages.last == .init(sender: .you, text: "Use the 2x shot."))
    }
}
