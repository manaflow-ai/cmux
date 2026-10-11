public import Foundation

/// An agent session (Claude Code, Codex, …) as the daemon's session journal
/// records it through agent hooks (cmux-tui/spec/session-journal.md, "Agent
/// adapters and ownership"). Folded by `AgentSessionFold`.
public nonisolated struct AgentSession: Hashable, Sendable, Codable {
    /// The session (machine) whose journal recorded it.
    public var machine: String
    /// The hook adapter id: `claude`, `codex`, `amp`, `opencode`, ….
    public var provider: String
    /// The provider's own session id (what `--resume` takes).
    public var sessionID: String
    public var cwd: String?
    /// Subjects of the latest event: the terminal and its tab, pane and
    /// workspace, when the hook ran inside a daemon terminal.
    public var terminal: String?
    public var tab: String?
    public var workspace: String?
    public var startedAt: Date
    public var lastActivityAt: Date
    public var endedAt: Date?

    public init(machine: String, provider: String, sessionID: String, cwd: String? = nil, terminal: String? = nil,
                tab: String? = nil, workspace: String? = nil, startedAt: Date, lastActivityAt: Date, endedAt: Date? = nil) {
        self.machine = machine
        self.provider = provider
        self.sessionID = sessionID
        self.cwd = cwd
        self.terminal = terminal
        self.tab = tab
        self.workspace = workspace
        self.startedAt = startedAt
        self.lastActivityAt = lastActivityAt
        self.endedAt = endedAt
    }

    /// `<machine>/<provider>/<session id>`.
    public var qualifiedID: String { "\(machine)/\(provider)/\(sessionID)" }

    /// The shell command that resumes this session, or nil when cmux does
    /// not know the provider's resume flag.
    public var resumeCommand: String? {
        AgentResume.command(provider: provider, sessionID: sessionID)
    }
}

/// Resume commands per provider.
public nonisolated enum AgentResume {
    public static func command(provider: String, sessionID: String) -> String? {
        let id = shellQuoted(sessionID)
        switch provider.lowercased() {
        case "claude", "claude-code", "claude_code": return "claude --resume \(id)"
        case "codex": return "codex resume \(id)"
        case "opencode": return "opencode --session \(id)"
        case "amp": return "amp threads continue \(id)"
        case "gemini": return "gemini --resume \(id)"
        default: return nil
        }
    }

    /// A single shell word: plain when it has only safe characters, else
    /// single-quoted with embedded quotes escaped.
    public static func shellQuoted(_ word: String) -> String {
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.:@/+=")
        if !word.isEmpty, word.unicodeScalars.allSatisfy(safe.contains) { return word }
        return "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// One session journal record, reduced to what the agent fold reads
/// (the record envelope of cmux-tui/spec/session-journal.md).
public nonisolated struct AgentJournalRecord: Hashable, Sendable, Decodable {
    public struct Subject: Hashable, Sendable, Decodable {
        public var kind: String
        public var id: String
    }

    public struct Payload: Hashable, Sendable, Decodable {
        public struct Adapter: Hashable, Sendable, Decodable { public var id: String }
        public struct Normalized: Hashable, Sendable, Decodable {
            public var agentSessionID: String?
            public var rootAgentSessionID: String?
            public var cwd: String?
            public var observedAtMs: String?

            enum CodingKeys: String, CodingKey {
                case agentSessionID = "agent_session_id"
                case rootAgentSessionID = "root_agent_session_id"
                case cwd
                case observedAtMs = "observed_at_ms"
            }
        }

        public var adapter: Adapter?
        public var normalized: Normalized?
    }

    public var sequence: UInt64
    public var kind: String
    public var occurredAtMs: Int64?
    public var subjects: [Subject]
    public var payload: Payload?

    enum CodingKeys: String, CodingKey {
        case sequence, kind, subjects, payload
        case occurredAtMs = "occurred_at_ms"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // The resource API sends the sequence as a decimal string.
        if let text = try? c.decode(String.self, forKey: .sequence), let value = UInt64(text) {
            sequence = value
        } else {
            sequence = try c.decode(UInt64.self, forKey: .sequence)
        }
        kind = try c.decode(String.self, forKey: .kind)
        if let text = try? c.decodeIfPresent(String.self, forKey: .occurredAtMs) {
            occurredAtMs = Int64(text)
        } else {
            occurredAtMs = try? c.decodeIfPresent(Int64.self, forKey: .occurredAtMs)
        }
        subjects = try c.decodeIfPresent([Subject].self, forKey: .subjects) ?? []
        payload = try c.decodeIfPresent(Payload.self, forKey: .payload)
    }

    public init(sequence: UInt64, kind: String, occurredAtMs: Int64?, subjects: [Subject], provider: String?,
                sessionID: String?, cwd: String? = nil) {
        self.sequence = sequence
        self.kind = kind
        self.occurredAtMs = occurredAtMs
        self.subjects = subjects
        self.payload = Payload(adapter: provider.map(Payload.Adapter.init(id:)),
                               normalized: Payload.Normalized(agentSessionID: sessionID, cwd: cwd))
    }

    func subject(_ kind: String) -> String? {
        subjects.first { $0.kind == kind }?.id
    }
}

nonisolated extension AgentJournalRecord.Subject {
    public init(_ kind: String, _ id: String) {
        self.kind = kind
        self.id = id
    }
}
