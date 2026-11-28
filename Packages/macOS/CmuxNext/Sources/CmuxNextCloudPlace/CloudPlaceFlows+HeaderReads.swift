import CmuxNextCloud
import CmuxNextCompat
import Foundation

// The chat header's reads that run per open chat (RFD main-thread row-bridge class): each is asked of Rust once per change
// of its facts, not once per header read, and the hybrid start's disk read runs off the main actor.
extension CloudPlaceFlows {
    /// The session's `start` (`{cloud, reason?, sinceMs?}`), as Rust reads its driver's newest Show; nil with none.
    /// Rust reads the driver's Show files from disk, so the read runs off the main actor: until it lands the header keeps the
    /// last answer, and ``startsLanded`` brings the new one in.
    func start(of session: String) -> Any? {
        _ = startsLanded // observed: a read that landed re-reads the header
        let revision = startRevision
        let kept = starts[session]
        if let kept, kept.revision == revision { return kept.start }
        guard let startState else {
            starts[session] = (revision, nil)
            return nil
        }
        guard startReads.insert(session).inserted else { return kept?.start }
        let core = core, stateDir = startState.path
        Task { @MainActor [weak self] in
            let reply = await Self.readStart(core, stateDir: stateDir, session: session)
            guard let self else { return }
            startReads.remove(session)
            var start: Any?
            // main-actor-ok: that chat's `{start: {cloud, reason?, sinceMs?}}`, a few scalars, once per Show.
            if let reply, let answer = try? JSONSerialization.jsonObject(with: reply) as? [String: Any],
               let value = answer["start"] as? [String: Any], JSONSerialization.isValidJSONObject(value) {
                start = value
            }
            // A read under an older revision still shows; the header's next read asks again.
            starts[session] = (revision, start)
            startsLanded &+= 1
        }
        return kept?.start
    }

    /// `cloud_hybrid_start` off the main actor: Rust reads the session's newest Show from disk.
    @concurrent nonisolated fileprivate static func readStart(_ core: Core, stateDir: String, session: String) async -> Data? {
        guard let request = try? JSONSerialization.data(withJSONObject: ["stateDir": stateDir, "session": session]) else { return nil }
        return core("cloud_hybrid_start", request)
    }

    /// Rust's `{blocked, holders, keep}` for `session` under `control`, asked once per change of the facts: the same facts
    /// (one row per open chat) read for every header would cost an encode and an FFI call per header, O(chats²) per sweep.
    func controlAnswer(session: String, control: ControlFacts) -> [String: Any]? {
        if controlAsked?.facts != control { controlAsked = (control, [:]) }
        if let known = controlAsked?.answers[session] { return known }
        // main-actor-ok: one row of eight scalars per open chat, sent once per change of the facts per chat, not per read.
        guard let request = try? JSONEncoder().encode(control.with(session: session)), let reply = core("cloud_move_place_control", request),
              // main-actor-ok: Rust's `{blocked, holders, keep}` for this chat's control.
              let answer = try? JSONSerialization.jsonObject(with: reply) as? [String: Any] else { return nil }
        controlAsked?.answers[session] = answer
        return answer
    }

    /// ``computerStatus(session:place:)``, reused while the chat's `at` and `start` are unchanged; a chat with a move in its
    /// place asks every read, since the move's facts carry the clock.
    func keptStatus(session: String, place: [String: Any]) -> Any? {
        guard place["move"] == nil else {
            statuses[session] = nil
            return computerStatus(session: session, place: place)
        }
        let at = place["at"] as? String ?? "", start = starts[session].map { $0.revision &* 2 &+ ($0.start == nil ? 0 : 1) } ?? -1
        if let kept = statuses[session], kept.at == at, kept.start == start { return kept.status }
        let status = computerStatus(session: session, place: place)
        statuses[session] = (at, start, status)
        return status
    }

    /// What Rust needs to say whether the header's cloud control is blocked or every slot is held (`priority::ControlFacts`).
    /// Facts only: a plan id is mapped to its slots in Rust (`priority::plan_of_id`); a plan not read is `planKnown: false`.
    public struct ControlFacts: Encodable, Sendable, Equatable {
        public struct Chat: Encodable, Sendable, Equatable {
            public var session: String, title: String, pin: String, at: String, hasWork: Bool, activeAtMs: UInt64
            public var priority: String, litAtMs: UInt64?
            public init(session: String, title: String, pin: String, at: String, hasWork: Bool, activeAtMs: UInt64 = 0,
                        priority: String = "normal", litAtMs: UInt64? = nil) {
                (self.session, self.title, self.pin, self.at, self.hasWork, self.activeAtMs) = (session, title, pin, at, hasWork, activeAtMs)
                (self.priority, self.litAtMs) = (priority, litAtMs)
            }
        }
        public var session = "", signedIn: Bool, restoring: Bool, planKnown: Bool, planId: String?, chats: [Chat]
        public init(signedIn: Bool, restoring: Bool, planKnown: Bool, planId: String?, chats: [Chat]) {
            (self.signedIn, self.restoring, self.planKnown, self.planId, self.chats) = (signedIn, restoring, planKnown, planId, chats)
        }
        func with(session: String) -> Self { var copy = self; copy.session = session; return copy }
    }

    /// The header control's facts (``ControlFacts``): `planId` is nil while no read kept a plan with an id (Rust would read a
    /// kept plan with no id as no plan at all), so a plan not read never claims No Plan or a full slot list; `chats` is read
    /// only when Rust will count slots (signed in, plan kept): a header with no plan never walks every tab.
    public func controlFacts(signedIn: Bool, restoring: Bool, planId: String?, chats: () -> [CloudPlaceChat]) -> ControlFacts {
        ControlFacts(signedIn: signedIn, restoring: restoring, planKnown: planId != nil, planId: planId, chats: planId == nil ? [] : controlChats(chats()))
    }

    /// ``ControlFacts/Chat`` for each chat the place controls see, pinned as the person set it here.
    public func controlChats(_ chats: [CloudPlaceChat]) -> [ControlFacts.Chat] {
        chats.map { chat in
            ControlFacts.Chat(session: chat.session, title: chat.title, pin: mode(of: chat.session, onCloud: chat.onCloud), at: chat.onCloud ? "cloud" : "local",
                              hasWork: chat.turnRunning || chat.queued > 0, activeAtMs: chat.turnStartedAtMs.flatMap { $0.isFinite && $0 > 0 ? UInt64($0) : nil } ?? 0,
                              priority: priority(of: chat.session), litAtMs: priorities[chat.session])
        }
    }
}
