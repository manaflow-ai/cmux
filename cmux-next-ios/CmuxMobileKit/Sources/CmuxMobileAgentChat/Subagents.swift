import Foundation

/// A subagent a session started (acpmux `_meta.acpmux.subagents`, see
/// cmux-tui/crates/acpmux/src/subagents.rs): native ACP subagent sessions and
/// Codex collaboration calls alike. `items` is its own transcript.
public struct AgentSubagent: Identifiable, Hashable, Sendable {
    public enum State: String, Hashable, Sendable {
        case running, completed, failed, cancelled, disconnected

        public var label: String {
            switch self {
            case .running: "Running"
            case .completed: "Done"
            case .failed: "Failed"
            case .cancelled: "Cancelled"
            case .disconnected: "Disconnected"
            }
        }
    }

    public var id: String
    /// The subagent that spawned it, or nil for the session's own.
    public var parent: String?
    public var name: String
    public var task: String?
    public var state: State
    public var startedAt: Date
    public var endedAt: Date?
    /// The title of its latest tool call.
    public var action: String?
    /// The turn it was spawned in (top-level subagents).
    public var turnID: String?
    public var items: [TurnItem] = []

    public init(id: String, parent: String?, name: String, task: String? = nil, state: State = .running,
                startedAt: Date, turnID: String? = nil) {
        self.id = id
        self.parent = parent
        self.name = name
        self.task = task
        self.state = state
        self.startedAt = startedAt
        self.turnID = turnID
    }

    public var duration: TimeInterval { (endedAt ?? Date()).timeIntervalSince(startedAt) }

    /// Its transcript as a turn, so the chat's row rules (tool groups, edits) apply.
    public var asTurn: AgentTurn {
        var turn = AgentTurn(id: "sub-\(id)", prompt: task ?? name, promptAt: startedAt)
        turn.items = items
        turn.status = state == .running ? .running : (state == .completed ? .completed : .failed)
        turn.startedAt = startedAt
        turn.endedAt = endedAt
        return turn
    }
}

/// A subagent transcript's turn and rows (`asTurn`, `rows`) for the screen that shows it, built
/// once per change of that subagent. A redraw for anything else (another subagent's token, the
/// parent chat) compares the subagent with the one last built, which is O(1) while its items
/// are untouched (an array compares its storage first).
@MainActor
final class SubagentRowsMemo {
    private var agent: AgentSubagent?
    private var turn: AgentTurn?
    private var rows: [TurnRow] = []
    /// The item each row starts at.
    private(set) var starts: [Int] = []
    /// Rows the last call kept as they were (all of them when the subagent did not change).
    private(set) var unchangedPrefix = 0
    private var permissionTools: Set<String> = []
    /// Times the subagent changed and its turn was taken again (tests: not once per redraw).
    private(set) var builds = 0
    /// Rows made (tests: an append makes the rows it changed, not the transcript's).
    private(set) var rowsMade = 0

    func rows(for agent: AgentSubagent) -> (turn: AgentTurn, rows: [TurnRow]) {
        if let last = self.agent, let turn, last == agent {
            unchangedPrefix = rows.count
            return (turn, rows)
        }
        builds += 1
        let turn = agent.asTurn
        let items = agent.items
        let tools = TurnRowBuilder.permissionTools(items)
        // Rows before the first changed item stay as they were; rows are made from there on.
        var keep = 0
        var from = 0
        if let last = self.agent, tools == permissionTools {
            let old = last.items
            let common = min(old.count, items.count)
            // A comparison per item (an untouched one compares its storage), no row made.
            var first = 0
            while first < common, old[first] == items[first] { first += 1 }
            from = first
            if let row = starts.lastIndex(where: { $0 <= first }) {
                switch rows[row] {
                case .tool, .toolGroup:
                    // A run of calls can grow: made again from its first call.
                    keep = row
                    from = starts[row]
                default:
                    keep = starts[row] == first ? row : row + 1
                }
            }
            // A run of calls just before can take the changed items in (a removed answer between
            // two runs joins them): made again from its first call too.
            if keep > 0 {
                switch rows[keep - 1] {
                case .tool, .toolGroup:
                    keep -= 1
                    from = starts[keep]
                default:
                    break
                }
            }
        }
        let made = TurnRowBuilder.rows(items, hidden: turn.hiddenToolCalls, permissionTools: tools, from: from)
        rowsMade += made.rows.count
        unchangedPrefix = keep
        rows.removeSubrange(keep...)
        starts.removeSubrange(keep...)
        rows += made.rows
        starts += made.starts
        self.agent = agent
        self.turn = turn
        permissionTools = tools
        return (turn, rows)
    }
}

/// The Subagents list's order: each subagent under its parent, with its depth. Built in one
/// pass when the set of subagents (ids and parents) changes, not when one changes state.
@MainActor
final class SubagentOrderMemo {
    private var ids: [String] = []
    private var parents: [String?] = []
    private var order: [(index: Int, depth: Int)] = []
    /// Subagents looked at while ordering (tests: each once per change of the set).
    private(set) var visits = 0
    /// Times the order was built.
    private(set) var builds = 0

    func ordered(_ agents: [AgentSubagent]) -> [(agent: AgentSubagent, depth: Int)] {
        let same = agents.count == ids.count && agents.indices.allSatisfy { agents[$0].id == ids[$0] && agents[$0].parent == parents[$0] }
        if !same { build(agents) }
        return order.map { (agents[$0.index], $0.depth) }
    }

    private func build(_ agents: [AgentSubagent]) {
        builds += 1
        ids = agents.map(\.id)
        parents = agents.map(\.parent)
        // Children in start order, as the list draws them.
        var children: [String: [Int]] = [:]
        var roots: [Int] = []
        for (index, agent) in agents.enumerated() {
            if let parent = agent.parent { children[parent, default: []].append(index) } else { roots.append(index) }
        }
        order = []
        var seen = Set<String>()
        var stack = roots.reversed().map { (index: $0, depth: 0) }
        while let entry = stack.popLast() {
            let agent = agents[entry.index]
            guard seen.insert(agent.id).inserted else { continue }
            visits += 1
            order.append(entry)
            stack += (children[agent.id] ?? []).reversed().map { (index: $0, depth: entry.depth + 1) }
        }
    }
}

/// One `_meta.acpmux.subagents` entry: a subagent started or changed.
public struct AgentSubagentChange: Hashable, Sendable {
    public var id: String
    public var parent: String?
    public var name: String?
    public var task: String?
    public var state: AgentSubagent.State?
    /// The tool call that started it (drawn by the subagent row instead).
    public var toolCallID: String?
    public var at: Date

    public init(id: String, parent: String? = nil, name: String? = nil, task: String? = nil, state: AgentSubagent.State? = nil,
                toolCallID: String? = nil, at: Date = Date()) {
        self.id = id
        self.parent = parent
        self.name = name
        self.task = task
        self.state = state
        self.toolCallID = toolCallID
        self.at = at
    }

    /// Decodes one entry of `_meta.acpmux.subagents`.
    public init?(_ value: JSONValue, at: Date) {
        guard let id = value["id"]?.stringValue else { return nil }
        let text = { (key: String) -> String? in
            guard let string = value[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !string.isEmpty else { return nil }
            return string
        }
        self.init(id: id, parent: text("parent"), name: text("name"), task: text("task") ?? text("prompt"),
                  state: text("state").flatMap(AgentSubagent.State.init(rawValue:)), toolCallID: text("toolCallId"), at: at)
    }
}

extension Array where Element == TurnItem {
    /// Appends a streamed update to a transcript (a subagent's own items).
    mutating func apply(_ update: ACPSessionUpdate) {
        switch update {
        case .agentMessageChunk(let text, let messageId):
            if case .message(let id, let existing)? = last, messageId == nil || messageId == id {
                self[count - 1] = .message(id: id, markdown: existing + text)
            } else {
                append(.message(id: messageId ?? UUID().uuidString, markdown: text))
            }
        case .agentThoughtChunk(let text):
            if case .thought(let id, let existing)? = last {
                self[count - 1] = .thought(id: id, text: existing + text)
            } else {
                append(.thought(id: UUID().uuidString, text: text))
            }
        case .toolCall(var call):
            call.startedAt = call.startedAt ?? Date()
            if let index = lastIndex(where: { if case .tool(let existing) = $0 { existing.id == call.id } else { false } }) {
                self[index] = .tool(call)
            } else {
                append(.tool(call))
            }
        case .toolCallUpdate(let update):
            if let index = lastIndex(where: { if case .tool(let existing) = $0 { existing.id == update.toolCallId } else { false } }),
               case .tool(var call) = self[index] {
                call.apply(update)
                if !call.isRunning, call.endedAt == nil { call.endedAt = Date() }
                self[index] = .tool(call)
            }
        case .plan(let entries):
            if let index = firstIndex(where: { if case .plan = $0 { true } else { false } }), case .plan(let id, _) = self[index] {
                self[index] = .plan(id: id, entries: entries)
            } else if !entries.isEmpty {
                append(.plan(id: UUID().uuidString, entries: entries))
            }
        default:
            break
        }
    }
}
