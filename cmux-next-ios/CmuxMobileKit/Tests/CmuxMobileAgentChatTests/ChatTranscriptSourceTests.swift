#if os(iOS)
@testable import CmuxMobileAgentChat
import Foundation
import Testing
import UIKit

/// The transcript list's source seam (#47189): an agent chat shows the rows it always did; a
/// subagent's transcript is the same list without the chat's turn rows.
@MainActor
@Suite struct ChatTranscriptSourceTests {
    static let at = SmoothChatTests.at

    static func shown(_ list: ChatTranscriptList) -> [String] {
        ChatRowsGoldenTests.shown(list)
    }

    static func subagentStore(task: String?, state: AgentSubagent.State) -> AgentChatStore {
        let store = AgentChatStore(source: SmoothChatTests.Silent())
        store.nextFrame = nil
        store.apply(.subagent(AgentSubagentChange(id: "s", name: "Probe", task: task, state: .running, at: at)))
        store.apply(.subagentUpdate(subagentID: "s", .agentThoughtChunk(text: "Thinking")))
        store.apply(.subagentUpdate(subagentID: "s", .toolCall(ACPToolCall(id: "c1", title: "Read a.swift", kind: .read, status: .completed))))
        store.apply(.subagentUpdate(subagentID: "s", .toolCall(ACPToolCall(id: "c2", title: "Read b.swift", kind: .read, status: .completed))))
        store.apply(.subagentUpdate(subagentID: "s", .agentMessageChunk(text: "Answer\n\n- one\n- two", messageId: "m1")))
        if state != .running { store.apply(.subagent(AgentSubagentChange(id: "s", state: state, at: at))) }
        return store
    }

    /// A subagent's transcript: its task, then its rows. No session line, no action row, no
    /// "Worked for" fold, no working, stopped or failed row; its prompt offers no Edit and Resend.
    @Test(arguments: [AgentSubagent.State.running, .completed, .failed])
    func aSubagentShowsItsTranscriptWithoutTheChatsTurnRows(_ state: AgentSubagent.State) throws {
        let store = Self.subagentStore(task: "Check the dialer", state: state)
        let list = ChatTranscriptList(store: store, surface: AgentChatSurface(), source: .subagent("s", store: store))
        list.foldsWork = false
        let ids = Self.shown(list)
        let rows = ids.compactMap { list.row($0) }
        #expect(rows.count == ids.count)
        for row in rows {
            switch row.kind {
            case .sessionStart, .actions, .worked, .working, .stopped, .failed, .editedFiles, .nextStep:
                Issue.record("a chat row in a subagent's transcript: \(row.id)")
            default: break
            }
        }
        // The pill, the task, the work, the footer.
        guard case .subagentOf(let parent)? = rows.first?.kind else { Issue.record("no pill first: \(ids)"); return }
        #expect(parent == store.summary.name, "a top-level subagent is the chat's")
        guard case .subagentFooter(let footer)? = rows.last?.kind else { Issue.record("no footer last: \(ids)"); return }
        #expect(footer.state == state)
        #expect(footer.text == (state == .running ? "Read b.swift" : state.label))
        guard case .prompt(let text, _, _, let isLast)? = rows.dropFirst().first?.kind else { Issue.record("no task second: \(ids)"); return }
        #expect(text == "Check the dialer")
        #expect(!isLast, "a subagent's task offers no Edit and Resend")
        #expect(rows.contains { if case .thought = $0.kind { true } else { false } })
        #expect(rows.contains { if case .toolGroup = $0.kind { true } else { false } })
        #expect(rows.contains { if case .block = $0.kind { true } else { false } })
        // The context reads the subagent's turn (a block's Copy takes its whole answer).
        #expect(list.context.messageText("m1") == "Answer\n\n- one\n- two")
    }

    @Test func aSubagentWithoutATaskStartsWithItsWork() {
        let store = Self.subagentStore(task: nil, state: .completed)
        let list = ChatTranscriptList(store: store, surface: AgentChatSurface(), source: .subagent("s", store: store))
        let rows = Self.shown(list).compactMap { list.row($0) }
        #expect(!rows.contains { if case .prompt = $0.kind { true } else { false } })
    }

    /// A nested subagent's pill names its parent subagent; a running subagent's footer says the
    /// Mac is offline when it is, with no spinner.
    @Test func aNestedSubagentsPillAndAnOfflineFooter() throws {
        let store = Self.subagentStore(task: "t", state: .running)
        store.apply(.subagent(AgentSubagentChange(id: "n", parent: "s", name: "Nested", task: "n", state: .running, at: Self.at)))
        let list = ChatTranscriptList(store: store, surface: AgentChatSurface(), source: .subagent("n", store: store))
        let rows = Self.shown(list).compactMap { list.row($0) }
        guard case .subagentOf(let parent)? = rows.first?.kind else { Issue.record("no pill"); return }
        #expect(parent == "Probe")
        var agent = try #require(store.subagent("s"))
        agent.action = "Read b.swift"
        let offline = SubagentFooter(agent, offline: true)
        #expect(offline.text == "Mac offline")
        #expect(offline.glyph == .disconnected)
        #expect(SubagentFooter(agent, offline: false).glyph == .running)
        agent.state = .completed
        #expect(SubagentFooter(agent, offline: true).text == "Done", "a finished subagent's footer stays its state offline")
    }

    /// Streamed text growing inside the subagent's answer reaches its row: the same row, its new
    /// text, no other row made again.
    @Test func streamedTextInsideAnAnswerReachesItsRow() async throws {
        let store = Self.subagentStore(task: "t", state: .running)
        let list = ChatTranscriptList(store: store, surface: AgentChatSurface(), source: .subagent("s", store: store))
        let ids = Self.shown(list)
        func answer() -> String {
            list.layout.items.compactMap { list.row($0.id) }.compactMap { row -> String? in
                guard case .block(let id, let block) = row.kind, id == "m1", case .paragraph(let text) = block.kind else { return nil }
                return text
            }.joined(separator: " ")
        }
        #expect(answer().hasPrefix("Answer"))
        for n in 0..<40 {
            store.apply(.subagentUpdate(subagentID: "s", .agentMessageChunk(text: " more\(n)", messageId: "m1")))
            list.reload()
        }
        let text = list.context.messageText("m1")
        #expect(text.hasSuffix("more39"), "the store's answer grew: \(text.suffix(40))")
        let rows = list.layout.items.compactMap { list.row($0.id) }
        let lastBlock = rows.compactMap { row -> String? in
            if case .block(let id, let block) = row.kind, id == "m1" { return String(describing: block.kind) } else { return nil }
        }.last ?? ""
        #expect(lastBlock.contains("more39"), "the answer's row shows the streamed text: \(lastBlock.suffix(80))")
        #expect(list.layout.items.map(\.id).filter { !$0.hasPrefix("m-m1#") } == ids.filter { !$0.hasPrefix("m-m1#") },
                "the other rows stay")
    }

    /// The subagent's records reach the list (it observes the subagent, not the chat's turns).
    @Test func aSubagentsRecordsReloadItsList() async {
        let store = Self.subagentStore(task: "t", state: .running)
        let list = ChatTranscriptList(store: store, surface: AgentChatSurface(), source: .subagent("s", store: store))
        let before = Self.shown(list).count
        store.apply(.subagentUpdate(subagentID: "s", .toolCall(ACPToolCall(id: "c9", title: "Search x", kind: .search, status: .completed))))
        for _ in 0..<20 where list.layout.items.count == before { await Task.yield() }
        #expect(list.layout.items.count > before, "the new row shows")
    }

    // MARK: The host

    /// A host in a window, laid out.
    static func host(_ store: AgentChatStore) -> (SubagentTranscriptHost, UIWindow) {
        let host = SubagentTranscriptHost(store: store, subagentID: "s")
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 500))
        window.rootViewController = host
        window.isHidden = false
        settle(window)
        return (host, window)
    }

    static func settle(_ window: UIWindow) {
        for _ in 0..<6 {
            window.layoutIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        }
    }

    static func long(_ store: AgentChatStore) {
        for n in 0..<30 {
            store.apply(.subagentUpdate(subagentID: "s", .agentMessageChunk(text: "Step \(n): the dialer retries with backoff.", messageId: "long\(n)")))
            store.apply(.subagentUpdate(subagentID: "s", .agentThoughtChunk(text: "thought \(n)")))
        }
    }

    /// A finished transcript opens at its top and stays there when a late update arrives.
    @Test func aFinishedTranscriptOpensAtTheTopAndStaysPut() {
        let store = Self.subagentStore(task: "t", state: .running)
        Self.long(store)
        store.apply(.subagent(AgentSubagentChange(id: "s", state: .completed, at: Self.at)))
        let (host, window) = Self.host(store)
        let view = host.list.collectionView
        #expect(host.positioned)
        #expect(!host.follows)
        let top = -view.adjustedContentInset.top
        #expect(abs(view.contentOffset.y - top) <= 0.5, "opens at the top: \(view.contentOffset.y), top \(top)")
        #expect(view.contentSize.height > view.bounds.height * 2, "the transcript is longer than the screen")
        // A late update (a nested subagent's state, an item replayed late) moves nothing.
        store.apply(.subagentUpdate(subagentID: "s", .agentMessageChunk(text: "late", messageId: "late")))
        Self.settle(window)
        #expect(abs(view.contentOffset.y - top) <= 0.5, "stays at the top: \(view.contentOffset.y)")
    }

    /// A running transcript opens on its end and follows it as rows come; scrolled away, it
    /// stops following; once the subagent finishes, it never follows.
    @Test func aRunningTranscriptFollowsItsEndOnlyWhileItRuns() {
        let store = Self.subagentStore(task: "t", state: .running)
        Self.long(store)
        let (host, window) = Self.host(store)
        let view = host.list.collectionView
        func bottom() -> CGFloat { view.contentSize.height + view.adjustedContentInset.bottom - view.bounds.height }
        #expect(host.follows)
        #expect(abs(view.contentOffset.y - bottom()) <= 0.5, "opens on the end")
        for n in 0..<5 {
            store.apply(.subagentUpdate(subagentID: "s", .toolCall(ACPToolCall(id: "f\(n)", title: "Run \(n)", kind: .execute, status: .completed))))
            store.apply(.subagentUpdate(subagentID: "s", .agentMessageChunk(text: "More \(n)", messageId: "more\(n)")))
            Self.settle(window)
            #expect(abs(view.contentOffset.y - bottom()) <= 0.5, "follows row \(n)")
        }
        // Finished: the end is not followed, and growth moves nothing.
        store.apply(.subagent(AgentSubagentChange(id: "s", state: .completed, at: Self.at)))
        Self.settle(window)
        #expect(!host.follows)
        let rest = view.contentOffset.y
        store.apply(.subagentUpdate(subagentID: "s", .agentMessageChunk(text: "after", messageId: "after")))
        Self.settle(window)
        #expect(abs(view.contentOffset.y - rest) <= 0.5, "a finished transcript does not follow")
    }
}
#endif
