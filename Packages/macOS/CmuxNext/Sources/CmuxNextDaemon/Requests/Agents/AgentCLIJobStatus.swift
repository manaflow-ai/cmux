import Foundation

/// One terminal outcome read on its captured job owner. Inventory, creation
/// acknowledgements and invalidations cannot produce this observation.
public nonisolated struct AgentCLIJobStatus: Decodable, Sendable, Equatable {
    /// Whether the owner still waits for the terminal or has an end observation.
    public enum State: String, Decodable, Sendable, Equatable {
        /// No terminal end observation yet.
        case pending
        /// An end observation exists; its outcome can still be unknown.
        case exited
    }

    /// The actual process result. Unknown never establishes update success.
    public enum Outcome: Decodable, Sendable, Equatable {
        /// The process's actual exit status.
        case exit(code: Int32)
        /// The process ended by this signal.
        case signal(number: Int32)
        /// No usable process result was observed; never an inferred success.
        case unknown

        private enum CodingKeys: String, CodingKey { case kind, code, signal }

        /// Keeps status/signal evidence and discards private diagnostic fields.
        public init(from decoder: any Decoder) throws {
            let fields = try decoder.container(keyedBy: CodingKeys.self)
            switch try fields.decode(String.self, forKey: .kind) {
            case "exit": self = .exit(code: try fields.decode(Int32.self, forKey: .code))
            case "signal": self = .signal(number: try fields.decode(Int32.self, forKey: .signal))
            default: self = .unknown
            }
        }
    }

    /// The durable terminal named by this observation.
    public let terminalID: ResourceID
    /// The terminal owner's pending/end observation, not a registry version change.
    public let state: State
    /// The process result only when state is exited.
    public let outcome: Outcome?
    /// The owner's observed end time in epoch milliseconds, when present.
    public let exitedAt: UInt64?
    /// The exact terminal-outcome cursor, independent of creation's topology revision.
    public let revision: UInt64

    private enum CodingKeys: String, CodingKey {
        case terminalID = "terminal_id", exitedAt = "exited_at"
        case state, lifecycle, outcome, revision
    }

    /// Decodes only a canonical terminal and the existing terminal.wait_exit union.
    public init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        terminalID = try fields.decode(ResourceID.self, forKey: .terminalID)
        state = try fields.decode(State.self, forKey: .state)
        let lifecycle = try fields.decode(String.self, forKey: .lifecycle)
        let cursor = try fields.decode(String.self, forKey: .revision)
        guard AgentCLIJobReceipt.validID(terminalID, scope: "term"),
              let revision = UInt64(cursor, radix: 10), String(revision) == cursor else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                debugDescription: "Invalid job terminal outcome identity or cursor"))
        }
        self.revision = revision
        switch state {
        case .pending:
            guard ["launching", "running"].contains(lifecycle),
                  !fields.contains(.outcome), !fields.contains(.exitedAt) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                    debugDescription: "A pending job cannot carry an exit result"))
            }
            outcome = nil
            exitedAt = nil
        case .exited:
            let timestamp = try fields.decode(String.self, forKey: .exitedAt)
            guard lifecycle == "exited", let exitedAt = UInt64(timestamp, radix: 10), String(exitedAt) == timestamp else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                    debugDescription: "Invalid job terminal exit time"))
            }
            self.exitedAt = exitedAt
            outcome = try fields.decode(Outcome.self, forKey: .outcome)
        }
    }
}
