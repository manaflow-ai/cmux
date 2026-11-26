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
        /// Composers holding unsent text; nil when unknown, or not read yet.
        public var unsentDrafts: Int?
        /// The console session's screen is locked; nil when unread (never evidence of away).
        public var screenLocked: Bool?
        /// Automatic installs declined in a row (the app did not quit for them).
        public var declinedInstalls: Int
        /// Seconds since the last declined install; nil when there was none.
        public var secondsSinceDecline: Double?

        public init(enabled: Bool, idleMinutes: Double, inputIdleSeconds: Double?, unsentDrafts: Int? = nil,
                    screenLocked: Bool? = nil, declinedInstalls: Int = 0, secondsSinceDecline: Double? = nil) {
            self.enabled = enabled
            self.idleMinutes = idleMinutes
            self.inputIdleSeconds = inputIdleSeconds.flatMap { $0.isFinite ? $0 : nil }
            self.unsentDrafts = unsentDrafts
            self.screenLocked = screenLocked
            self.declinedInstalls = max(0, declinedInstalls)
            self.secondsSinceDecline = secondsSinceDecline.flatMap { $0.isFinite ? $0 : nil }
        }
    }

    /// Why the update waits.
    public nonisolated enum UpdateIdleHold: String, Decodable, Equatable, Sendable {
        case off, notIdle, unsentDraft, unknown
        /// The last automatic install was declined; the next try waits out a backoff.
        case backoff
    }

    /// The decision: nil installs now. A pinned FFI without the op (or a reply this build cannot
    /// read) holds as unknown: Update When Idle never installs on a guess.
    public func updateIdleHold(_ facts: UpdateIdleFacts) -> UpdateIdleHold? {
        updateIdleDecision(facts).hold
    }

    /// The decision and, when it installs, the away reading it acted on ("screen locked",
    /// "no input for 14 min") for the updater's log.
    public func updateIdleDecision(_ facts: UpdateIdleFacts) -> (hold: UpdateIdleHold?, away: String?) {
        struct Hold: Decodable { var reason: String }
        struct Away: Decodable { var kind: String; var seconds: Double? }
        struct Reply: Decodable { var install: Bool; var hold: Hold?; var away: Away? }
        guard let reply = call("window_update_idle_install", facts, as: Reply.self) else { return (.unknown, nil) }
        if reply.install {
            let away = reply.away.map { away in
                away.kind == "screenLocked" ? "screen locked" : "no input for \(Int((away.seconds ?? 0) / 60)) min"
            }
            return (nil, away)
        }
        return (reply.hold.flatMap { UpdateIdleHold(rawValue: $0.reason) } ?? .unknown, nil)
    }

    /// Settings > Updates' Next Check: seconds from now until the updater's next scheduled check (0 when
    /// due), nil when automatic checks are off or the FFI cannot answer.
    public func updateNextCheck(secondsSinceLastCheck: Double?, intervalSeconds: Double) -> Double? {
        struct Facts: Encodable { var secondsSinceLastCheck: Double?; var intervalSeconds: Double }
        struct Reply: Decodable { var inSeconds: Double? }
        let since = secondsSinceLastCheck.flatMap { $0.isFinite ? $0 : nil }
        return call("window_update_next_check", Facts(secondsSinceLastCheck: since, intervalSeconds: intervalSeconds), as: Reply.self)?.inSeconds
    }
}
