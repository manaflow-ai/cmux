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
        /// Where each agent runs as followed, and what the next read finds.
        var sessions: [String: HomeAgentSessionRef] = [:]
        var nextRead: [HomeAgentSessionRef] = []
        var reads: [[String]] = []
        func agentSession(_ peer: String, in conversation: ConversationID) -> HomeAgentSessionRef? { sessions[peer] }
        func followAgentSessions(_ peers: [String], in conversation: ConversationID) async -> Bool {
            reads.append(peers)
            var moved = false
            for seen in nextRead where peers.contains(seen.peer) {
                if var known = sessions[seen.peer] { moved = known.follow(seen) || moved; sessions[seen.peer] = known } else { sessions[seen.peer] = seen }
            }
            return moved
        }
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

    @Test func goToWorkspaceShowsOnlyForALinkedAgentAndOpensItsLink() async throws {
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
        // The click reads where the agent runs first (slice 3 step 2), then opens.
        await view.pendingGo?.value
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

    // MARK: Slice 3 step 2: follow an agent by its session id and re-attach where it moved

    @Test func goToWorkspaceGoesWhereTheAgentsSessionRunsNow() async throws {
        let chiefLink = try #require(URL(string: "cmux://chief/0123abcd/session/s-81"))
        let threads = Threads()
        threads.threads = ["a1": Self.thread("a1", title: "Linked", link: chiefLink)]
        let pane = HomeAgentPane(conversation: ConversationID("c"), threads: threads)
        pane.open("a1")
        // Not moved: the Chief's own link to it.
        threads.nextRead = [HomeAgentSessionRef(peer: "a1", session: "s-81")]
        #expect(await pane.goToWorkspace("a1") == chiefLink)
        #expect(threads.reads.last == ["a1"])
        // A Chief move handed it to a mini (a higher epoch): the session's own link, where acpmux has it now,
        // and the header names the machine.
        threads.nextRead = [HomeAgentSessionRef(peer: "a1", session: "s-81", place: "cmux-mini", spawnEpoch: 1)]
        #expect(await pane.goToWorkspace("a1") == URL(string: "cmux://session/s-81"))
        let content = try #require(pane.content("a1", now: .distantFuture))
        #expect(content.place == "cmux-mini")
        #expect(content.workspaceLink == URL(string: "cmux://session/s-81"))
        // An older read leaves it where it went.
        threads.nextRead = [HomeAgentSessionRef(peer: "a1", session: "s-81", place: nil)]
        #expect(await pane.goToWorkspace("a1") == URL(string: "cmux://session/s-81"))
        #expect(pane.content("a1", now: .distantFuture)?.place == "cmux-mini")
    }

    @Test func aMovedAgentsHeaderNamesWhereItRuns() {
        let thread = Self.thread("a1", title: "Fix", link: URL(string: "cmux://chief/0123abcd/session/s-81"))
        let here = HomeAgentChatContent(thread, now: .distantFuture, session: HomeAgentSessionRef(peer: "a1", session: "s-81"))
        #expect(here.place == nil && here.workspaceLink == URL(string: "cmux://chief/0123abcd/session/s-81"))
        let moved = HomeAgentChatContent(thread, now: .distantFuture,
                                         session: HomeAgentSessionRef(peer: "a1", session: "s-81", place: "cloud", moveEpoch: 2))
        #expect(moved.place == "cloud" && moved.workspaceLink == URL(string: "cmux://session/s-81"))
        // A ref of another session (the Chief restarted the agent) is not this chat's.
        let other = HomeAgentChatContent(thread, now: .distantFuture,
                                         session: HomeAgentSessionRef(peer: "a1", session: "s-99", place: "cloud", moveEpoch: 2))
        #expect(other.place == nil && other.workspaceLink == URL(string: "cmux://chief/0123abcd/session/s-81"))
    }

    /// User 2026-11-04 (msg 21663): "i dont like these splits … just open it as pane to right side". A click on a
    /// linked agent's pill hands its link to the host (as its `aN` link does), which opens a real tab right of
    /// Home, never the chat's own inline split; its report is seen. An agent with no link, or a host that cannot
    /// open it, keeps the inline pane so the click still shows something.
    @Test func aLinkedPillOpensARealPaneBesideHomeNotTheInlineSplit() throws {
        let link = try #require(URL(string: "cmux://chief/0123abcd/session/s-81"))
        let threads = Threads()
        threads.threads = ["a1": Self.thread("a1", title: "Linked", link: link), "a2": Self.thread("a2", title: "Not linked")]
        let pane = HomeAgentPane(conversation: ConversationID("c"), threads: threads)
        var opened: [URL] = []
        pane.open("a1", outside: { opened.append($0); return true })
        #expect(opened == [link])
        #expect(!pane.isShown && pane.tabs.isEmpty)
        #expect(threads.seen == ["a1"])
        // No link: nothing to open beside Home, so the inline pane shows it.
        pane.open("a2", outside: { opened.append($0); return true })
        #expect(opened == [link] && pane.tabs == ["a2"])
        // A host that could not open it: the inline pane, never nothing.
        pane.open("a1", outside: { _ in false })
        #expect(pane.tabs == ["a2", "a1"] && pane.selected == "a1")
    }
}
