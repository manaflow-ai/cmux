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
            let source = RigSource()
            let store = AgentChatStore(source: source)
            seedTranscript(store, items: max(settings.count, 0), running: settings.streams, giant: settings.giant)
            // `late`: the stream starts after `edgeAfter` seconds (a reader at rest at the end first).
            if settings.streams, settings.edge != "late", settings.edge != "follow" {
                live = streamTranscript(store, source: source, hz: settings.liveHz, textOnly: settings.edge == "text")
            }
            let holder = RigStoreHolder(store: store)
            switch settings.edge {
            case "follow":
                // The reader rests on the end (set by the screen's position, not a gesture) and the
                // stream starts at LIST_LIVE_HZ (default 50): the probe measures the follow.
                holder.probe = FollowProbe()
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(settings.edgeAfter))
                    holder.probe?.armed = true
                    live = streamTranscript(store, source: source, hz: settings.liveHz)
                }
            case "late" where settings.streams:
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(settings.edgeAfter))
                    live = streamTranscript(store, source: source, hz: settings.liveHz)
                }
            case "removed":
                // The chat's records go (its chat closed, or a history that no longer has it).
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(settings.edgeAfter))
                    live?.cancel()
                    holder.store = AgentChatStore(source: RigSource())
                }
            case "offline":
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(settings.edgeAfter))
                    source.offline = true
                }
            case "burst":
                // 1000 items reach the open subagent in one main-actor turn (`receive`, as a
                // Mac's records do): 500 tool runs, each followed by a token of the answer.
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(settings.edgeAfter))
                    for n in 0..<500 {
                        store.receive(.subagentUpdate(subagentID: transcriptID, .toolCall(ACPToolCall(
                            id: "rig-burst-c\(n)", title: "Burst step \(n)", kind: .read, status: .completed))))
                        store.receive(.subagentUpdate(subagentID: transcriptID, .agentMessageChunk(text: "burst\(n) ", messageId: "rig-burst-m\(n)")))
                    }
                }
            default: break
            }
            root = AnyView(NavigationStack { RigTranscript(holder: holder) })
        case "subagents":
            let store = AgentChatStore(source: RigSource())
            let running = seedSubagents(store, count: max(settings.count, 0))
            if let hz = settings.liveHz, hz > 0 { live = churnSubagents(store, running: running, hz: hz) }
            root = AnyView(NavigationStack { SubagentsScreen(store: store, surface: AgentChatSurface()) })
        case "inspector":
            // `LIST_COUNT=-1`: a chat whose records don't come from a Mac (no journal).
            let journal = settings.count < 0 ? nil : AgentEventJournal()
            if let journal {
                for n in 0..<settings.count { journal.record(record(n, giant: settings.giant)) }
                live = feedInspector(journal, settings: settings)
                if settings.edge == "drop" {
                    // The oldest records, at the list's end where the reader waits, drop.
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(settings.edgeAfter))
                        for n in settings.count..<(settings.count + 60) { journal.record(record(n)) }
                    }
                } else if settings.edge == "burst" {
                    // 2000 records over about 50 frames (the `events-burst` burst), at a set time,
                    // in a frame-interval window ("inspector-burst", with `CMUX_MOBILE_FRAMELOG=1`)
                    // whose summary a UI test reads ("list.burst.frames").
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(settings.edgeAfter))
                        FrameIntervalLog.shared.begin("inspector-burst")
                        var seq = settings.count
                        for _ in 0..<50 {
                            for _ in 0..<40 {
                                journal.record(record(seq))
                                seq += 1
                            }
                            try? await Task.sleep(for: .milliseconds(20))
                        }
                        // The last frames' publish and layout.
                        try? await Task.sleep(for: .milliseconds(500))
                        if let stats = FrameIntervalLog.shared.end() { BurstFrames.shared.line = BurstFrames.describe(stats) }
                    }
                } else if settings.edge == "offline" {
                    // The Mac goes away mid-scroll: no more records arrive.
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(settings.edgeAfter))
                        live?.cancel()
                        live = nil
                    }
                }
            }
            root = AnyView(NavigationStack { EventInspectorScreen(journal: journal, sessionID: "rig") }
                .overlay(alignment: .bottomLeading) { BurstFramesProbe() })
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
    /// `items: 0`: no items and no task (the pill and the footer only). `giant`: the second item
    /// is a pasted raw log far taller than the screen.
    static func seedTranscript(_ store: AgentChatStore, items: Int, running: Bool, giant: Bool = false) {
        let start = Date().addingTimeInterval(-600)
        store.apply(.subagent(AgentSubagentChange(id: transcriptID, name: "WireGuard dialer",
                                                  task: items == 0 ? nil : "Check the WireGuard dialer's retry path and measure its backoff",
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
            if giant, index == 1 {
                store.apply(.subagentUpdate(subagentID: transcriptID,
                                            .agentMessageChunk(text: MockStressContent.giantPrompt(index), messageId: "rig-giant")))
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
    /// `hz` (`LIST_LIVE_HZ`): tokens a second instead of 50.
    /// `textOnly` (`CMUX_MOBILE_LIST_EDGE=text`): tokens into one answer and nothing else, so the
    /// only change the transcript sees is text growing inside an existing item.
    static func streamTranscript(_ store: AgentChatStore, source: RigSource, hz: Double? = nil, textOnly: Bool = false) -> Task<Void, Never> {
        let interval = Duration.seconds(1 / max(hz ?? 50, 0.1))
        return Task { @MainActor in
            var tick = 0
            var message = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                // Nothing comes from a Mac that is offline.
                if source.offline { continue }
                tick += 1
                store.receive(.subagentUpdate(subagentID: transcriptID, .agentMessageChunk(text: "token\(tick) ", messageId: "rig-live-m\(message)")))
                if tick % 25 == 0, !textOnly {
                    let id = "rig-live-c\(tick)"
                    store.receive(.subagentUpdate(subagentID: transcriptID, .toolCall(ACPToolCall(id: id, title: "swift build (\(tick))", kind: .execute))))
                    store.receive(.subagentUpdate(subagentID: transcriptID, .toolCallUpdate(ACPToolCallUpdate(toolCallId: id, status: .completed,
                                                                                                                content: [.content(.text("Build complete"))]))))
                    message += 1
                }
                if tick % 50 == 0, !textOnly {
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
    /// `giant`: record seq 10 is about 400 KB, over the journal's 256 KB record cap.
    static func record(_ n: Int, giant: Bool = false) -> JSONValue {
        let kinds = ["agent_message_chunk", "tool_call", "tool_call_update", "agent_thought_chunk", "plan"]
        let kind = kinds[n % kinds.count]
        let text = giant && n == 9
            ? String(repeating: "output line \(n) of an oversized tool result\n", count: 10_000)
            : n % 25 == 24
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

/// The rig's store, swapped for an empty one by `CMUX_MOBILE_LIST_EDGE=removed`.
@MainActor @Observable
final class RigStoreHolder {
    var store: AgentChatStore
    @ObservationIgnored var probe: FollowProbe?
    init(store: AgentChatStore) { self.store = store }
}

private struct RigTranscript: View {
    let holder: RigStoreHolder

    var body: some View {
        SubagentTranscriptScreen(store: holder.store, surface: AgentChatSurface(), subagentID: ListStressChatScreens.transcriptID,
                                 probe: holder.probe)
    }
}

/// A chat with no records of its own: the rig writes them. `offline`: its Mac can't be reached.
@Observable
final class RigSource: AgentSessionSource {
    var offline = false
    var isOffline: Bool { offline }
    let summary = AgentSessionSummary(id: "rig", name: "Rig chat", harness: "claude", agentName: "Claude", cwd: "~/Development/cmux",
                                      workspaceTitle: "cmux", macName: "Studio")
    func events() -> AsyncStream<AgentSessionEvent> { AsyncStream { _ in } }
    func send(_ intent: AgentClientIntent) {}
}

/// The rig's burst window summary (`LIST_EDGE=burst` on the inspector), for UI tests.
@MainActor @Observable
final class BurstFrames {
    static let shared = BurstFrames()
    var line = ""

    static func describe(_ stats: FrameIntervalStats) -> String {
        var line = stats.line
        if let cpu = stats.mainThreadCPUPerFrameMs, !cpu.isEmpty {
            let sorted = cpu.sorted()
            let p99 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.99))]
            line += String(format: " cpu_p99=%.1fms cpu_max=%.1fms", p99, sorted.last ?? 0)
        }
        return line
    }
}

/// An invisible element with the burst window's summary ("list.burst.frames").
private struct BurstFramesProbe: View {
    var body: some View {
        Text(BurstFrames.shared.line.isEmpty ? "pending" : BurstFrames.shared.line)
            .font(.system(size: 1))
            .foregroundStyle(.clear)
            .frame(width: 2, height: 2)
            .allowsHitTesting(false)
            .accessibilityIdentifier("list.burst.frames")
    }
}
#endif
