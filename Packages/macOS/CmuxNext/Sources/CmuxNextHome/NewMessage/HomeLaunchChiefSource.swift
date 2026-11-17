public import CmuxHomeCore
public import Foundation

/// The owner behind a bare launch's message box: one Chief conversation that only exists on this
/// Mac, so Home's composer (the same box, glass and header as the real Chief's) takes keys before
/// the Chief's owner answers (no remembered Chief, nothing listed yet). Its summary is titled with
/// the Chief's name, with me and a Chief as members, so the header and the box sit where the real
/// Chief's will. A send goes to `hold` with its key and waits there until the page names the real
/// Chief (``LaunchChiefHold/resolve(_:deliver:)``). Every other op is refused.
public struct HomeLaunchChiefSource: HomeSource {
    /// The provisional conversation's id (never an owner's id).
    public static let conversation = ConversationID("cmux.home.launch-chief")
    /// The provisional Chief member: this Mac's default Chief's id (`HomeChiefName.muxID`), so the
    /// Chief view reads the same Chief home (avatar, engine, settings) the default Chief's page does.
    public static let chiefID = ParticipantID("agent_mux")
    public let me: Participant
    /// The header's name: the Chief's.
    public let title: String
    public let hold: LaunchChiefHold

    /// Creates the source.
    /// - Parameters:
    ///   - me: The signed-in person.
    ///   - title: The Chief's name (`HomeStrings.chiefName`).
    ///   - hold: Keeps each send until the real Chief is known.
    public init(me: Participant, title: String, hold: LaunchChiefHold) {
        self.me = me
        self.title = title
        self.hold = hold
    }

    private var summary: ConversationSummary {
        let start = Date(timeIntervalSince1970: 0)
        let chief = Participant(id: Self.chiefID, kind: .agent, displayName: title, agentClass: .chief)
        return ConversationSummary(id: Self.conversation, owner: .local, title: title, participants: [me, chief], createdAt: start, updatedAt: start)
    }

    public func events() async -> AsyncStream<HomeEvent> {
        let snapshot = InboxSnapshot(me: me, conversations: [summary], rev: 1)
        // Two events, then nothing: a cap of two never drops one.
        return AsyncStream(bufferingPolicy: .bufferingNewest(2)) { continuation in
            continuation.yield(.connection(.online))
            continuation.yield(.inbox(snapshot))
        }
    }

    public func inbox() async throws -> InboxSnapshot { InboxSnapshot(me: me, conversations: [summary], rev: 1) }

    public func snapshot(of conversation: ConversationID, tail: Int) async throws -> ConversationPage {
        guard conversation == Self.conversation else { throw HomeRejection.invalid("launch_chief.unknown_conversation") }
        return ConversationPage(conversation: summary, messages: [])
    }

    public func history(of conversation: ConversationID, before beforeSeq: Seq, limit: Int) async throws -> [Message] { [] }

    public func submit(_ intent: HomeIntent) async throws -> HomeOpResult {
        guard case .sendMessage(let conversation, let parts, _, _) = intent.op, conversation == Self.conversation else {
            throw HomeRejection.invalid("launch_chief.unsupported")
        }
        return try await hold.hold(parts, key: intent.key)
    }

    public func search(_ query: String, limit: Int) async throws -> [HomeSearchHit] { [] }

    public func resolve(_ contact: ContactAddress) async throws -> ContactResolution {
        throw HomeRejection.invalid("launch_chief.unsupported")
    }
}

/// The sends made in a bare launch's message box before the Chief's owner answered: kept in the
/// order made, each under the key its intent had, until the page names the real Chief. Resolved
/// once: every held send then goes to the Chief through `deliver` with its own key, one at a time
/// in order, and exactly once (a resend of a key already handed over gets the same answer).
/// Cancelled before that (the page went), the held parts come back to the caller, never dropped.
@MainActor
public final class LaunchChiefHold {
    /// Posts one held send to the real Chief under its original key (the real store owns it from
    /// there: its offline queue and Not Delivered state).
    public typealias Deliver = @MainActor (_ chief: ConversationID, _ parts: [MessagePart], _ key: IdempotencyKey) async -> Void

    private struct Held {
        let key: IdempotencyKey
        let parts: [MessagePart]
        var waiters: [CheckedContinuation<HomeOpResult, any Error>]
    }

    private var held: [Held] = []
    /// Each key handed to `deliver`, with the answer its sender got.
    private var delivered: [IdempotencyKey: HomeOpResult] = [:]
    private var deliver: Deliver?
    private var draining = false
    /// Who waits for the Chief to be named (``resolved()``).
    private var resolveWaiters: [CheckedContinuation<ConversationID?, Never>] = []
    /// The real Chief, once named.
    public private(set) var chief: ConversationID?
    public private(set) var isCancelled = false

    public init() {}

    /// The sends still waiting for the Chief, in order.
    public var heldParts: [[MessagePart]] { held.map(\.parts) }

    /// Keeps `parts` under `key` until the Chief is named, then answers with the Chief's
    /// conversation once it was handed over. Throws when the hold was cancelled first.
    public func hold(_ parts: [MessagePart], key: IdempotencyKey) async throws -> HomeOpResult {
        if let answer = delivered[key] { return answer }
        guard !isCancelled else { throw HomeRejection.invalid("launch_chief.cancelled") }
        return try await withCheckedThrowingContinuation { continuation in
            if let index = held.firstIndex(where: { $0.key == key }) {
                held[index].waiters.append(continuation)
            } else {
                held.append(Held(key: key, parts: parts, waiters: [continuation]))
            }
            drain()
        }
    }

    /// Keeps `parts` under `key` with no one waiting for the answer (a send stage 0's box made
    /// before this page existed: ``HomeLaunchComposer/take(_:)``), after the sends held already.
    /// False when the hold was cancelled (the caller keeps the text).
    @discardableResult
    public func keep(_ parts: [MessagePart], key: IdempotencyKey) -> Bool {
        guard !isCancelled else { return false }
        guard delivered[key] == nil, !held.contains(where: { $0.key == key }) else { return true }
        held.append(Held(key: key, parts: parts, waiters: []))
        drain()
        return true
    }

    /// The real Chief is `chief`: each held send goes to it through `deliver`, in order. Once;
    /// a later call, or one after ``cancel()``, does nothing.
    public func resolve(_ chief: ConversationID, deliver: @escaping Deliver) {
        guard self.chief == nil, !isCancelled else { return }
        self.chief = chief
        self.deliver = deliver
        drain()
        endWaits(with: chief)
    }

    /// The real Chief once it is named (at once when it is), for what the page's settings card
    /// was asked before then (a rename, an engine change): it applies to the Chief then. Nil when
    /// the hold was cancelled first (the page went or quit before its Chief answered).
    public func resolved() async -> ConversationID? {
        if let chief { return chief }
        guard !isCancelled else { return nil }
        return await withCheckedContinuation { resolveWaiters.append($0) }
    }

    private func endWaits(with chief: ConversationID?) {
        let waiters = resolveWaiters
        resolveWaiters = []
        for waiter in waiters { waiter.resume(returning: chief) }
    }

    /// Ends the hold before the Chief was named: each waiting send is refused and its parts come
    /// back, in order, for the draft. After ``resolve(_:deliver:)`` nothing is cancelled (the
    /// held sends are the Chief's already) and this returns none.
    @discardableResult
    public func cancel() -> [[MessagePart]] {
        guard chief == nil, !isCancelled else { return [] }
        isCancelled = true
        let parts = held.map(\.parts)
        let waiters = held.flatMap(\.waiters)
        held = []
        for waiter in waiters { waiter.resume(throwing: HomeRejection.invalid("launch_chief.cancelled")) }
        endWaits(with: nil)
        return parts
    }

    /// The text of `parts`, one held send per paragraph (what a cancel gives back to the draft).
    public static func text(of parts: [[MessagePart]]) -> String {
        parts.map { send in
            send.compactMap { part in if case .text(let text, _) = part { text } else { nil } }.joined()
        }.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    private func drain() {
        guard let chief, let deliver, !draining, !held.isEmpty else { return }
        draining = true
        // task-owner: one pass over the held sends; ends when none is left (main actor: this class's)
        Task {
            while let next = held.first {
                await deliver(chief, next.parts, next.key)
                let answer = HomeOpResult(rev: 0, conversation: chief)
                delivered[next.key] = answer
                // A resend of the same key that arrived meanwhile waits on this entry too.
                let done = held.removeFirst()
                for waiter in done.waiters { waiter.resume(returning: answer) }
            }
            draining = false
        }
    }
}
