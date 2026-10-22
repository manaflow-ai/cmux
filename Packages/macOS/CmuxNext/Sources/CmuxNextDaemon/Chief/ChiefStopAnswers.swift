/// The answer to `chief.stop {all: true}`.
public nonisolated struct ChiefStopAll: Decodable, Sendable, Equatable {
    /// Whether the Chief's own turn was running and stopped.
    public var stopped: Bool
    /// The subagents that stopped, in id order.
    public var subagents: [String]

    public init(stopped: Bool, subagents: [String]) {
        self.stopped = stopped
        self.subagents = subagents
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        stopped = try c.decodeIfPresent(Bool.self, forKey: .stopped) ?? false
        subagents = try c.decodeIfPresent([String].self, forKey: .subagents) ?? []
    }

    private enum CodingKeys: String, CodingKey { case stopped, subagents }
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
