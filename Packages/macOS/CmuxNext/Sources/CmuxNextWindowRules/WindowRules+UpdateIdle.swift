/// Update When Idle (`updates.installWhenIdle`): whether a staged app update installs now, or why it
/// waits (cmux-window-rules `update_idle`). The updater asks once a second while an update waits.
extension WindowRules {
    /// What the app knows now.
    public nonisolated struct UpdateIdleFacts: Encodable, Equatable, Sendable {
        public var enabled: Bool
        /// `updates.installWhenIdleMinutes`.
        public var idleMinutes: Double
        /// Seconds since the last keyboard or pointer input; nil when unread.
        public var inputIdleSeconds: Double?
        /// Agent turns running on this Mac; nil when the daemon did not answer, or not read yet.
        public var runningTurns: Int?
        /// Composers holding unsent text; nil when unknown, or not read yet.
        public var unsentDrafts: Int?

        public init(enabled: Bool, idleMinutes: Double, inputIdleSeconds: Double?, runningTurns: Int? = nil, unsentDrafts: Int? = nil) {
            self.enabled = enabled
            self.idleMinutes = idleMinutes
            self.inputIdleSeconds = inputIdleSeconds.flatMap { $0.isFinite ? $0 : nil }
            self.runningTurns = runningTurns
            self.unsentDrafts = unsentDrafts
        }
    }

    /// Why the update waits.
    public nonisolated enum UpdateIdleHold: String, Decodable, Equatable, Sendable {
        case off, notIdle, agentWorking, unsentDraft, unknown
    }

    /// The decision: nil installs now. A pinned FFI without the op (or a reply this build cannot
    /// read) holds as unknown: Update When Idle never installs on a guess.
    public func updateIdleHold(_ facts: UpdateIdleFacts) -> UpdateIdleHold? {
        struct Hold: Decodable { var reason: String }
        struct Reply: Decodable { var install: Bool; var hold: Hold? }
        guard let reply = call("window_update_idle_install", facts, as: Reply.self) else { return .unknown }
        if reply.install { return nil }
        return reply.hold.flatMap { UpdateIdleHold(rawValue: $0.reason) } ?? .unknown
    }
}
