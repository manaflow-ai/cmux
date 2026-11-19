// DEBUG and Demo builds only: the list scroll rig's agent chat screens (verify/listperf/).
#if os(iOS) && DEBUG
import CmuxMobileDesign
import SwiftUI
import UIKit

/// A subagent's transcript, the Subagents list and the Event Inspector on generated data, with
/// their live load (`ListStressSettings`), for `ListStressRig` (CmuxMobileShell) to present and
/// scroll. Live records go through the paths a Mac's do: `AgentChatStore.receive` and
/// `AgentEventJournal.record`.
extension ListStressSettings {
    /// This rig screen (`subagent`, `subagents`, `inspector`) in a navigation stack with its load
    /// started, or nil for another screen.
    @MainActor
    public func chatScreen() -> UIViewController? {
        guard let screen else { return nil }
        return ListStressChatScreens.make(screen, settings: self)
    }
}

@MainActor
enum ListStressChatScreens {
    /// The running load (kept until the app exits after its passes).
    private static var live: Task<Void, Never>?

    /// The screen in a navigation stack with its load started, or nil for another screen.
    static func make(_ screen: String, settings: ListStressSettings) -> UIViewController? {
        let root: AnyView
        switch screen {
        case "subagent":
            let store = AgentChatStore(source: RigSource())
            seedTranscript(store, items: max(settings.count, 1), running: settings.streams)
            if settings.streams { live = streamTranscript(store) }
            root = AnyView(NavigationStack {
                SubagentTranscriptScreen(store: store, surface: AgentChatSurface(), subagentID: transcriptID)
            })
        case "subagents":
            let store = AgentChatStore(source: RigSource())
            let running = seedSubagents(store, count: max(settings.count, 3))
            if let hz = settings.liveHz, hz > 0 { live = churnSubagents(store, running: running, hz: hz) }
            root = AnyView(NavigationStack { SubagentsScreen(store: store, surface: AgentChatSurface()) })
        case "inspector":
            // `LIST_COUNT=-1`: a chat whose records don't come from a Mac (no journal).
            let journal = settings.count < 0 ? nil : AgentEventJournal()
            if let journal {
                for n in 0..<settings.count { journal.record(record(n)) }
                live = feedInspector(journal, settings: settings)
            }
            root = AnyView(NavigationStack { EventInspectorScreen(journal: journal, sessionID: "rig") })
        default:
            return nil
        }
        let controller = UIHostingController(rootView: root)
        controller.modalPresentationStyle = .fullScreen
        return controller
    }

    // MARK: Subagent transcript

    static let transcriptID = "rig-sub"

    /// One subagent with `items` transcript items (messages, thoughts, tool runs, an edit, a
    /// nested subagent halfway), plus 5 siblings.
    static func seedTranscript(_ store: AgentChatStore, items: Int, running: Bool) {
        let start = Date().addingTimeInterval(-600)
        store.apply(.subagent(AgentSubagentChange(id: transcriptID, name: "WireGuard dialer",
                                                  task: "Check the WireGuard dialer's retry path and measure its backoff",
                                                  state: .running, at: start)))
        for sibling in 0..<5 {
            store.apply(.subagent(AgentSubagentChange(id: "rig-sib\(sibling)", name: "Sibling \(sibling)", task: "Check part \(sibling)",
                                                      state: .running, at: start)))
        }
        for index in 0..<items {
            if index == items / 2 {
                store.apply(.subagent(AgentSubagentChange(id: "rig-nested", parent: transcriptID, name: "Relay probe",
                                                          task: "Measure the relay round trip", state: .running, at: start)))
                for nested in 0..<10 { store.apply(.subagentUpdate(subagentID: "rig-nested", item(nested))) }
                store.apply(.subagent(AgentSubagentChange(id: "rig-nested", state: .completed, at: start.addingTimeInterval(30))))
                continue
            }
            store.apply(.subagentUpdate(subagentID: transcriptID, item(index)))
        }
        if !running {
            store.apply(.subagent(AgentSubagentChange(id: transcriptID, state: .completed, at: start.addingTimeInterval(300))))
        }
    }

    /// A transcript item by its index: an answer, tool runs that group, a thought, shell output,
    /// an edit with a diff.
    static func item(_ index: Int) -> ACPSessionUpdate {
        switch index % 10 {
        case 0, 8:
            return .agentMessageChunk(text: "Step \(index): the dialer retries **\(index % 5 + 1)** times with backoff.\n\n"
                + "- the first retry waits 250 ms\n- later ones double, up to 8 s\n\nThe relay keeps the session while it does.",
                                      messageId: "rig-m\(index)")
        case 1, 2, 3:
            let path = "Sources/Transport/File\(index).swift"
            return .toolCall(ACPToolCall(id: "rig-c\(index)", title: "Read \(path)", kind: .read, status: .completed,
                                         locations: [.init(path: path)]))
        case 4:
            return .agentThoughtChunk(text: "Checking whether item \(index)'s timeout covers the handshake.")
        case 5:
            let output = (0..<12).map { "Test Case 'Rig\(index).test\($0)' passed (0.0\($0) seconds)" }.joined(separator: "\n")
            return .toolCall(ACPToolCall(id: "rig-c\(index)", title: "swift test --filter Rig\(index)", kind: .execute, status: .completed,
                                         content: [.content(.text(output))],
                                         rawInput: .object(["command": .string("swift test --filter Rig\(index)")])))
        case 6:
            let old = (0..<12).map { "let value\($0) = \($0)" }.joined(separator: "\n")
            let new = (0..<12).map { $0 % 4 == 0 ? "let value\($0) = \($0 * 2) // doubled" : "let value\($0) = \($0)" }.joined(separator: "\n")
            return .toolCall(ACPToolCall(id: "rig-c\(index)", title: "Edit Sources/Edit\(index).swift", kind: .edit, status: .completed,
                                         content: [.diff(path: "Sources/Edit\(index).swift", oldText: old, newText: new)],
                                         locations: [.init(path: "Sources/Edit\(index).swift")]))
        case 7:
            return .toolCall(ACPToolCall(id: "rig-c\(index)", title: "Search retryDelay", kind: .search, status: .completed,
                                         rawInput: .object(["pattern": .string("retryDelay")])))
        default:
            return .toolCall(ACPToolCall(id: "rig-c\(index)", title: "Fetch https://example.com/rfc\(index)", kind: .fetch, status: .completed))
        }
    }

    /// A token every 20 ms, a tool call every 500 ms (the answer goes on in a new message after
    /// it), and the 5 siblings changing state once a second.
    static func streamTranscript(_ store: AgentChatStore) -> Task<Void, Never> {
        Task { @MainActor in
            var tick = 0
            var message = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(20))
                tick += 1
                store.receive(.subagentUpdate(subagentID: transcriptID, .agentMessageChunk(text: "token\(tick) ", messageId: "rig-live-m\(message)")))
                if tick % 25 == 0 {
                    let id = "rig-live-c\(tick)"
                    store.receive(.subagentUpdate(subagentID: transcriptID, .toolCall(ACPToolCall(id: id, title: "swift build (\(tick))", kind: .execute))))
                    store.receive(.subagentUpdate(subagentID: transcriptID, .toolCallUpdate(ACPToolCallUpdate(toolCallId: id, status: .completed,
                                                                                                                content: [.content(.text("Build complete"))]))))
                    message += 1
                }
                if tick % 50 == 0 {
                    for sibling in 0..<5 {
                        let state: AgentSubagent.State = (tick / 50 + sibling) % 2 == 0 ? .running : .completed
                        store.receive(.subagent(AgentSubagentChange(id: "rig-sib\(sibling)", state: state)))
                    }
                }
            }
        }
    }

    // MARK: Subagents list

    /// `count` subagents in threes: a top-level one, its child and its grandchild. Returns the
    /// ids of the 10 that keep running.
    static func seedSubagents(_ store: AgentChatStore, count: Int) -> [String] {
        let start = Date().addingTimeInterval(-900)
        var running: [String] = []
        for index in 0..<count {
            let root = "rig-a\(index / 3)"
            let id = index % 3 == 0 ? root : (index % 3 == 1 ? "\(root)-b" : "\(root)-b-c")
            let parent: String? = index % 3 == 0 ? nil : (index % 3 == 1 ? root : "\(root)-b")
            let runs = index % 6 == 0 && running.count < 10
            store.apply(.subagent(AgentSubagentChange(id: id, parent: parent, name: "Subagent \(index)",
                                                      task: "Check part \(index) of the transport", state: .running,
                                                      at: start.addingTimeInterval(Double(index)))))
            store.apply(.subagentUpdate(subagentID: id, .toolCall(ACPToolCall(id: "rig-t\(index)", title: "Read File\(index).swift", kind: .read))))
            if runs {
                running.append(id)
            } else {
                store.apply(.subagent(AgentSubagentChange(id: id, state: .completed, at: start.addingTimeInterval(Double(index + 60)))))
            }
        }
        return running
    }

    /// The running ones change action and state `hz` times a second.
    static func churnSubagents(_ store: AgentChatStore, running: [String], hz: Double) -> Task<Void, Never> {
        Task { @MainActor in
            var tick = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1 / hz))
                tick += 1
                for (index, id) in running.enumerated() {
                    store.receive(.subagentUpdate(subagentID: id, .toolCall(ACPToolCall(id: "rig-live-\(id)-\(tick)", title: "Run step \(tick)", kind: .execute))))
                    let state: AgentSubagent.State = (tick + index) % 4 == 0 ? .completed : .running
                    store.receive(.subagent(AgentSubagentChange(id: id, state: state)))
                }
            }
        }
    }

    // MARK: Event Inspector

    /// An acpmux record: mostly short updates, every 25th a tool result of about 160 KB (under
    /// the journal's 256 KB record cap), so 500 records come near its 4 MB budget.
    static func record(_ n: Int) -> JSONValue {
        let kinds = ["agent_message_chunk", "tool_call", "tool_call_update", "agent_thought_chunk", "plan"]
        let kind = kinds[n % kinds.count]
        let text = n % 25 == 24
            ? String(repeating: "output line \(n) of a long tool result\n", count: 4000)
            : "Reading Sources/Transport/File\(n).swift and checking the retry path"
        let update: JSONValue = .object(["sessionUpdate": .string(kind), "content": .object(["type": .string("text"), "text": .string(text)])])
        return .object([
            "seq": .number(Double(n + 1)), "at": .number((Date().timeIntervalSince1970 * 1000).rounded()),
            "dir": .string(n % 7 == 0 ? "out" : "in"), "kind": .string("session_update"),
            "msg": .object(["method": .string("session/update"), "params": .object(["sessionId": .string("rig"), "update": update])]),
        ])
    }

    /// `LIST_STREAM=1`: 2000 records in one second once the scroll starts, then 20 a second.
    /// `LIST_LIVE_HZ`: records a second from the start. `LIST_FILTER`: the filter typed a
    /// character every 100 ms, then cleared, over and over.
    static func feedInspector(_ journal: AgentEventJournal, settings: ListStressSettings) -> Task<Void, Never>? {
        var seq = settings.count
        func next() -> JSONValue {
            defer { seq += 1 }
            return record(seq)
        }
        let typing: Task<Void, Never>? = settings.filter.map { filter in
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(settings.openDelay + 3))
                while !Task.isCancelled {
                    for length in 1...max(filter.count, 1) {
                        DemoDirector.shared.post(.inspectorFilter(String(filter.prefix(length))))
                        try? await Task.sleep(for: .milliseconds(100))
                    }
                    try? await Task.sleep(for: .milliseconds(400))
                    DemoDirector.shared.post(.inspectorFilter(""))
                    try? await Task.sleep(for: .milliseconds(400))
                }
            }
        }
        guard settings.streams || settings.liveHz != nil || typing != nil else { return nil }
        return Task { @MainActor in
            defer { typing?.cancel() }
            if settings.streams {
                // The rig scrolls after the open window and its settle.
                try? await Task.sleep(for: .seconds(settings.openDelay + 2.6 + settings.settle + 0.5))
                for _ in 0..<50 {
                    for _ in 0..<40 { journal.record(next()) }
                    try? await Task.sleep(for: .milliseconds(20))
                }
            }
            let hz = settings.liveHz ?? (settings.streams ? 20 : 0)
            guard hz > 0 else {
                while !Task.isCancelled { try? await Task.sleep(for: .seconds(1)) }
                return
            }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1 / hz))
                journal.record(next())
            }
        }
    }
}

/// A chat with no records of its own: the rig writes them.
private final class RigSource: AgentSessionSource {
    let summary = AgentSessionSummary(id: "rig", name: "Rig chat", harness: "claude", agentName: "Claude", cwd: "~/Development/cmux",
                                      workspaceTitle: "cmux", macName: "Studio")
    func events() -> AsyncStream<AgentSessionEvent> { AsyncStream { _ in } }
    func send(_ intent: AgentClientIntent) {}
}
#endif
