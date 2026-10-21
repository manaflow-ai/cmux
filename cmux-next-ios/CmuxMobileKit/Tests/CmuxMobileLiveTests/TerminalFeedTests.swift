import CmuxMobileFeed
import CmuxMobileModel
import Foundation
import Testing
@testable import CmuxMobileLive

/// Terminal agents (Codex, Claude Code in a Mac terminal tab) reach the Feed
/// through the daemon's notification ledger, not acpmux.
@MainActor
@Suite struct TerminalFeedTests {
    /// The Mac: a workspace with a Codex terminal (surface 1), a second
    /// terminal (surface 2), an agent chat tab (surface 7) and a browser (surface 9).
    static func tree(codex: String = "blocked", markers: String = "") -> DaemonTree {
        let reply = Data("""
        {"ok":true,"data":{"workspaces":[{"id":4,"key":"ws-a","title":"cmux","screens":[{"id":3,"active":true,"active_pane":2,"panes":[{"id":2,"active_tab":0,"tabs":[
          {"surface":1,"kind":"pty","title":"codex","cwd":"/Users/me/src/cmux"\(markers)},
          {"surface":2,"kind":"pty","title":"zsh","cwd":"/Users/me/src/cmux"},
          {"surface":7,"kind":"conversation","title":"","conversation":{"agent_session":{"host":"install:x","session":"sess-1","harness":"claude"}}},
          {"surface":9,"kind":"browser","title":"Docs","url":"https://cmux.com"}
        ]}]}]}]}}
        """.utf8)
        var agents = AgentStates()
        agents.bySurface[1] = AgentState(state: codex, agent: "codex")
        return try! DaemonTree(reply: reply, macID: "mac", agents: agents)
    }

    static func row(_ id: String, _ title: String, body: String = "", level: String = "info", surface: Int?, at ms: Int,
                    source: String = "agent", acknowledged: Bool = false) -> String {
        let surface = surface.map(String.init) ?? "null"
        return #"{"id":"\#(id)","title":"\#(title)","subtitle":null,"body":"\#(body)","level":"\#(level)","terminal_id":"term_x","surface":\#(surface),"created_at_ms":\#(ms),"source":"\#(source)","acknowledged":\#(acknowledged)}"#
    }

    /// A fake `daemon` channel: the ledger it answers with, and every request it got.
    final class FakeDaemon {
        var rows: [String] = []
        var requests: [(String, [String: Int])] = []

        func respond(_ command: String, _ params: [String: Int]) -> Data {
            requests.append((command, params))
            switch command {
            case "list-notifications":
                return Data(#"{"ok":true,"data":{"notifications":[\#(rows.reversed().joined(separator: ","))]}}"#.utf8)
            default:
                return Data(#"{"ok":true,"data":{}}"#.utf8)
            }
        }

        var lists: Int { requests.count { $0.0 == "list-notifications" } }
        var acks: [Int] { requests.filter { $0.0 == "ack-tab-notifications" }.compactMap { $0.1["surface"] } }
    }

    static func make(_ daemon: FakeDaemon) -> (FeedStore, TerminalFeed) {
        let store = FeedStore(items: [])
        let feed = TerminalFeed(store: store)
        feed.request = { command, params, _ in daemon.respond(command, params) }
        store.onItemsChange = { [weak feed] items in feed?.itemsChanged(items) }
        return (store, feed)
    }

    static func settle(_ condition: () -> Bool) async {
        for _ in 0..<500 where !condition() { await Task.yield() }
    }

    static let connection = 1

    @Test func hydratesTerminalAgentEventsOnConnect() async {
        let daemon = FakeDaemon()
        daemon.rows = [
            Self.row("ntf_1", "Codex finished", surface: 1, at: 1_000_000),
            Self.row("ntf_2", "Codex needs approval", body: "shell", level: "warning", surface: 1, at: 2_000_000),
            // The agent chat tab's own notice: LiveFeed has that chat.
            Self.row("ntf_3", "Claude finished", surface: 7, at: 3_000_000),
            Self.row("ntf_4", "Page", surface: 9, at: 3_100_000),
            Self.row("ntf_5", "Build done", surface: nil, at: 3_200_000, source: "cli"),
            // A closed tab: nothing to open.
            Self.row("ntf_6", "Codex finished", surface: 99, at: 3_300_000),
            // Codex's own OSC 9 for the same turn as the hook's.
            Self.row("ntf_7", "Codex", body: "Agent turn complete", surface: 1, at: 1_002_000, source: "terminal"),
            Self.row("ntf_8", "Tests failed", level: "error", surface: 2, at: 4_000_000, source: "cli"),
        ]
        let (store, feed) = Self.make(daemon)
        feed.treeChanged(Self.tree(), macID: "mac", connection: Self.connection)
        await Self.settle { store.items.count == 3 }

        #expect(store.items.map(\.id) == ["term-mac-ntf_8", "term-mac-ntf_2", "term-mac-ntf_1"])
        let finished = store.item(id: "term-mac-ntf_1")
        #expect(finished?.kind == .finished)
        #expect(finished?.agentName == "Codex")
        #expect(finished?.harness == "codex")
        #expect(finished?.workspaceID == "ws-a")
        #expect(finished?.workspaceTitle == "cmux")
        #expect(finished?.tabID == "s1")
        #expect(finished?.markdown == "Finished its turn in the terminal. Open it to see the result.")
        #expect(finished?.opensTerminal == true)
        #expect(finished?.createdAt == Date(timeIntervalSince1970: 1000))

        let waiting = store.item(id: "term-mac-ntf_2")
        #expect(waiting?.kind == .needsInput)
        #expect(waiting?.needsYou == true)
        #expect(waiting?.markdown == "**Needs approval:** shell")
        #expect(store.needsYouCount == 1)

        let failed = store.item(id: "term-mac-ntf_8")
        #expect(failed?.kind == .failed)
        #expect(failed?.agentName == "Terminal")
        #expect(failed?.markdown == "Tests failed.")
        #expect(daemon.requests.first.map { $0.0 } == "list-notifications")
        #expect(daemon.requests.first?.1 == ["limit": 100])
    }

    @Test func liveNotificationsGoOnTopAndRelistOnlyWhenNeeded() async {
        let daemon = FakeDaemon()
        daemon.rows = [Self.row("ntf_1", "Codex finished", surface: 1, at: 1_000_000)]
        let (store, feed) = Self.make(daemon)
        feed.treeChanged(Self.tree(codex: "working"), macID: "mac", connection: Self.connection)
        await Self.settle { store.items.count == 1 }
        #expect(daemon.lists == 1)

        // The same tree again (a title change): no ledger read.
        feed.treeChanged(Self.tree(codex: "working"), macID: "mac", connection: Self.connection)
        await Self.settle { false }
        #expect(daemon.lists == 1)

        // The daemon posts: the new row is read and goes on top.
        daemon.rows.append(Self.row("ntf_2", "Codex asked a question", level: "warning", surface: 1, at: 5_000_000))
        feed.notificationPosted()
        await Self.settle { store.items.count == 2 }
        #expect(store.items.first?.id == "term-mac-ntf_2")
        #expect(store.items.first?.kind == .needsInput)
        #expect(store.items.first?.markdown == "Asked a question.")

        // A tab's unread marker changed (a post or a read on the Mac): read again.
        feed.treeChanged(Self.tree(codex: "blocked", markers: #","notification":{"notification":2,"unread":true}"#), macID: "mac",
                         connection: Self.connection)
        await Self.settle { daemon.lists == 3 }
        #expect(daemon.lists == 3)
        #expect(store.items.count == 2)
    }

    @Test func readsSyncBothWays() async {
        let daemon = FakeDaemon()
        daemon.rows = [
            Self.row("ntf_1", "Codex finished", surface: 1, at: 1_000_000, acknowledged: true),
            Self.row("ntf_2", "Codex finished", surface: 2, at: 2_000_000),
        ]
        let (store, feed) = Self.make(daemon)
        feed.treeChanged(Self.tree(), macID: "mac", connection: Self.connection)
        await Self.settle { store.items.count == 2 }

        // Read on the Mac: read here, and nothing is acknowledged back.
        #expect(store.item(id: "term-mac-ntf_1")?.isRead == true)
        #expect(store.item(id: "term-mac-ntf_2")?.isRead == false)
        #expect(daemon.acks.isEmpty)

        // Read on the phone: the Mac marks that tab read, once.
        store.markRead("term-mac-ntf_2")
        await Self.settle { !daemon.acks.isEmpty }
        #expect(daemon.acks == [2])
        store.markUnread("term-mac-ntf_2")
        store.markRead("term-mac-ntf_2")
        await Self.settle { false }
        #expect(daemon.acks == [2])

        // Unread again on the phone after the Mac read it: the phone's choice stands.
        store.markUnread("term-mac-ntf_1")
        feed.notificationPosted()
        await Self.settle { daemon.lists == 2 }
        await Self.settle { false }
        #expect(store.item(id: "term-mac-ntf_1")?.isRead == false)
    }

    @Test func waitingTerminalResolvesWhenItMovesOn() async {
        let daemon = FakeDaemon()
        daemon.rows = [
            Self.row("ntf_1", "Codex needs approval", level: "warning", surface: 1, at: 1_000_000),
            Self.row("ntf_2", "Claude needs approval", level: "warning", surface: 2, at: 1_500_000),
        ]
        let (store, feed) = Self.make(daemon)
        feed.treeChanged(Self.tree(codex: "blocked"), macID: "mac", connection: Self.connection)
        await Self.settle { store.items.count == 2 }
        #expect(store.needsYouCount == 2)
        #expect(store.item(id: "term-mac-ntf_2")?.agentName == "Claude")

        // Codex works again: answered in its terminal.
        feed.treeChanged(Self.tree(codex: "working"), macID: "mac", connection: Self.connection)
        #expect(store.item(id: "term-mac-ntf_1")?.resolution == "Answered in the terminal")
        #expect(store.item(id: "term-mac-ntf_1")?.needsYou == false)

        // The other terminal posts again: its ask is behind it.
        daemon.rows.append(Self.row("ntf_3", "Claude finished", surface: 2, at: 9_000_000))
        feed.notificationPosted()
        await Self.settle { store.items.count == 3 }
        #expect(store.item(id: "term-mac-ntf_2")?.resolution == "Answered in the terminal")
        #expect(store.needsYouCount == 0)
    }

    /// The person declined in the terminal, or quit the agent: no longer waiting.
    @Test func aQuitTerminalNoLongerWaits() async {
        let daemon = FakeDaemon()
        daemon.rows = [Self.row("ntf_1", "Codex needs approval", level: "warning", surface: 1, at: 1_000_000)]
        let (store, feed) = Self.make(daemon)
        feed.treeChanged(Self.tree(codex: "blocked"), macID: "mac", connection: Self.connection)
        await Self.settle { store.items.count == 1 }
        #expect(store.needsYouCount == 1)
        feed.treeChanged(Self.tree(codex: "done"), macID: "mac", connection: Self.connection)
        #expect(store.item(id: "term-mac-ntf_1")?.resolution == "Answered in the terminal")
    }

    @Test func aNewConnectionHydratesAgainWithoutDuplicates() async {
        let daemon = FakeDaemon()
        daemon.rows = [Self.row("ntf_1", "Codex finished", surface: 1, at: 1_000_000)]
        let (store, feed) = Self.make(daemon)
        feed.treeChanged(Self.tree(), macID: "mac", connection: Self.connection)
        await Self.settle { store.items.count == 1 }
        store.markDone("term-mac-ntf_1")

        feed.treeChanged(Self.tree(), macID: "mac", connection: 2)
        await Self.settle { daemon.lists == 2 }
        await Self.settle { false }
        #expect(store.items.count == 1)
        #expect(store.item(id: "term-mac-ntf_1")?.isDone == true)
    }

    /// Review findings: a terminal that went to work before it ever asked does
    /// not answer its first ask; a hook's event replaces the terminal's own echo
    /// shown before it; reading an older event does not mark the tab read.
    @Test func firstAskWaitsEchoesGoAndOnlyTheNewestReadMarksTheTab() async {
        let daemon = FakeDaemon()
        let (store, feed) = Self.make(daemon)
        feed.treeChanged(Self.tree(codex: "idle"), macID: "mac", connection: Self.connection)
        await Self.settle { daemon.lists == 1 }
        feed.treeChanged(Self.tree(codex: "working"), macID: "mac", connection: Self.connection)
        daemon.rows = [Self.row("ntf_1", "Codex", body: "Approval requested: touch x", surface: 1, at: 1_000_000, source: "terminal")]
        feed.notificationPosted()
        await Self.settle { store.items.count == 1 }
        #expect(store.item(id: "term-mac-ntf_1")?.needsYou == true)

        daemon.rows.append(Self.row("ntf_2", "Codex needs approval", body: "touch x", level: "warning", surface: 1, at: 1_001_000))
        feed.notificationPosted()
        await Self.settle { store.item(id: "term-mac-ntf_1") == nil }
        #expect(store.items.map(\.id) == ["term-mac-ntf_2"])
        #expect(store.item(id: "term-mac-ntf_2")?.needsYou == true)

        daemon.rows.append(Self.row("ntf_3", "Codex finished", surface: 1, at: 9_000_000))
        feed.notificationPosted()
        await Self.settle { store.items.count == 2 }
        store.markRead("term-mac-ntf_2")
        await Self.settle { false }
        #expect(daemon.acks.isEmpty)
        store.markRead("term-mac-ntf_3")
        await Self.settle { !daemon.acks.isEmpty }
        #expect(daemon.acks == [1])
    }

    @Test func wordsAndKinds() {
        func entry(_ title: String, body: String = "", level: String = "info", source: String = "agent") -> TerminalFeed.Entry {
            TerminalFeed.Entry(json: ["id": "n", "title": title, "body": body, "level": level, "source": source])!
        }
        #expect(TerminalFeed.kind(entry("Codex finished")) == .finished)
        #expect(TerminalFeed.kind(entry("Codex reported an error", level: "error")) == .failed)
        #expect(TerminalFeed.kind(entry("Codex requested plan review", level: "warning")) == .needsInput)
        // An OSC notification is read by its words.
        #expect(TerminalFeed.kind(entry("Codex", body: "Approval requested: rm -rf build", source: "terminal")) == .needsInput)
        #expect(TerminalFeed.kind(entry("Codex", body: "Agent turn complete", source: "terminal")) == .finished)
        #expect(TerminalFeed.text(entry("Codex", body: "Agent turn complete"), agentName: "Codex", kind: .finished) == "Agent turn complete")
        #expect(TerminalFeed.text(entry("Build", body: "ok"), agentName: "Terminal", kind: .finished) == "**Build:** ok")
        #expect(TerminalFeed.text(entry(""), agentName: "Terminal", kind: .needsInput) == "Needs your input.")
        #expect(TerminalFeed.harness(title: "Claude finished") == "claude")
        #expect(TerminalFeed.harness(title: "Build done") == nil)
    }

    @Test func theDaemonSaysWhenANotificationIsPosted() throws {
        #expect(DaemonEvent.parse(Data(#"{"event":"notification","notification":3,"title":"Codex finished","surface":1,"source":"agent"}"#.utf8)) == .notification)
        let tree = Self.tree(markers: #","notification":{"notification":3,"unread":true,"level":"info","source":"agent"}"#)
        #expect(tree.notificationMarkers == [1: DaemonTree.NotificationMarker(notification: 3, unread: true)])
    }

    @Test func archiveKeepsTerminalEvents() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "terminal-feed-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        var finished = FeedItem(id: "term-mac-1", kind: .finished, workspaceID: "ws", tabID: "s1", agentName: "Codex", harness: "codex",
                                workspaceTitle: "cmux", markdown: "Finished.", quote: nil, createdAt: Date(timeIntervalSince1970: 10))
        finished.opensTerminal = true
        var waiting = finished
        waiting.id = "term-mac-2"
        waiting.kind = .needsInput
        FeedArchive(url: url).save([finished, waiting])
        let loaded = FeedArchive(url: url).load()
        // An open ask is read again from the Mac, never from the archive.
        #expect(loaded.map(\.id) == ["term-mac-1"])
        #expect(loaded.first?.opensTerminal == true)
    }
}
