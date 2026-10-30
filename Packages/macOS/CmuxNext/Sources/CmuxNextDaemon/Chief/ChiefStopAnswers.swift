/// The answer to `chief.stop {all: true}`.
public nonisolated struct ChiefStopAll: Decodable, Sendable, Equatable {
    /// Whether the Chief's own turn was running and stopped.
    public var stopped: Bool
    /// The subagents that stopped, in id order.
    public var subagents: [String]
    /// One line per subagent whose cancel acpmux refused ("a2: its turn did
    /// not stop: ..."): it goes on and is not in `subagents`. Empty from a
    /// daemon older than this key.
    public var errors: [String]
    /// Set when a stopped subagent was still starting ("a1 is still
    /// starting; it stops as soon as it starts."); nil otherwise and from
    /// an older daemon.
    public var note: String?

    public init(stopped: Bool, subagents: [String], errors: [String] = [], note: String? = nil) {
        self.stopped = stopped
        self.subagents = subagents
        self.errors = errors
        self.note = note
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        stopped = try c.decodeIfPresent(Bool.self, forKey: .stopped) ?? false
        subagents = try c.decodeIfPresent([String].self, forKey: .subagents) ?? []
        errors = try c.decodeIfPresent([String].self, forKey: .errors) ?? []
        note = try c.decodeIfPresent(String.self, forKey: .note)
    }

    private enum CodingKeys: String, CodingKey { case stopped, subagents, errors, note }
}

/// The answer to `chief.stop {restart: [ids]}`.
public nonisolated struct ChiefRestart: Decodable, Sendable, Equatable {
    /// The subagents that go on again.
    public var restarted: [String]
    /// One line per subagent that could not.
    public var errors: [String]

    public init(restarted: [String], errors: [String]) {
        self.restarted = restarted
        self.errors = errors
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        restarted = try c.decodeIfPresent([String].self, forKey: .restarted) ?? []
        errors = try c.decodeIfPresent([String].self, forKey: .errors) ?? []
    }

    private enum CodingKeys: String, CodingKey { case restarted, errors }
}
