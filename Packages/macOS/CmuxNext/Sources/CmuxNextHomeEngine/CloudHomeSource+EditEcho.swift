import CmuxHomeCore
import CmuxNextDaemon
import CmuxNextHomeModel
import CmuxNextWakeups
import Foundation

nonisolated extension CloudHomeSource {
    // MARK: Edit echo

    /// An edit of `conversation` starts: a deadline waiting for an earlier
    /// edit's echo waits for this one's op too.
    func beginEdit(_ conversation: ConversationID, generation: UInt64) {
        editEcho(conversation, .begin(conversation: conversation.rawValue, generation: generation))
    }

    /// An edit's op answered (`committedAt`: its revision) or was refused
    /// (`final`: the store never resends it). Once no edit of the
    /// conversation is in flight, the subscription ends when the newest
    /// committed edit's echo has arrived, or at once when nothing waits for
    /// one; otherwise at the echo or at the deadline, whichever comes
    /// first. A transcript that shows the conversation keeps its own.
    func finishEdit(_ conversation: ConversationID, generation: UInt64, committedAt rev: UInt64?, final: Bool) {
        editEcho(conversation, .finish(conversation: conversation.rawValue, generation: generation, committedAt: rev, final: final))
    }

    /// A conversation event at `rev`: the echo of a held edit ends its subscription.
    func echoed(_ conversation: ConversationID, rev: UInt64) {
        editEcho(conversation, .echoed(conversation: conversation.rawValue, rev: rev))
    }

    private func editDeadlinePassed(_ conversation: ConversationID, generation: UInt64) {
        // An edit in flight arms the deadline again when it answers.
        editEcho(conversation, .deadline(conversation: conversation.rawValue, generation: generation))
    }

    /// One step of `conversation`'s hold, decided by the Rust rules (`cloud.echo_step`,
    /// cmux-home-rules `cloud/edit_echo.rs`); the timer and the unsubscribe stay here.
    private func editEcho(_ conversation: ConversationID, _ event: EchoEvent) {
        state.withLock { state in
            let key = conversation.rawValue
            let holds = EchoHolds(
                generation: state.generation,
                holds: state.editHolds[conversation].map { [key: EchoHold($0)] } ?? [:],
                viewed: state.viewed.contains(conversation) ? [key] : []
            )
            guard let reply: EchoStepReply = try? HomeRules.call("cloud.echo_step", EchoStepRequest(state: holds, event: event))
            else { return }
            // The hold as Rust left it; the deadline timer is this side's.
            if let hold = reply.state.holds[key] {
                var held = state.editHolds[conversation]
                    ?? CloudHomeState.EditHold(deadline: DemandTimer(owner: "App.homeCloud.editEcho", clock: clock))
                held.inFlight = Int(hold.inFlight)
                held.awaited = hold.awaited
                held.seen = hold.seen
                state.editHolds[conversation] = held
            }
            for effect in reply.effects {
                switch effect {
                case .cancelDeadline:
                    state.editHolds[conversation]?.deadline.cancel()
                case .scheduleDeadline(let afterMs):
                    let generation = state.generation
                    state.editHolds[conversation]?.deadline.schedule(after: .milliseconds(afterMs)) { [weak self] in
                        self?.editDeadlinePassed(conversation, generation: generation)
                    }
                case .endSubscription:
                    state.endEditSubscription(conversation)
                }
            }
            if reply.state.holds[key] == nil { state.editHolds[conversation] = nil }
        }
    }
}

/// `cloud.echo_step`'s wire (cmux-home-rules `cloud/edit_echo.rs`).
private nonisolated struct EchoHold: Codable {
    var inFlight: UInt64
    var awaited: UInt64?
    var seen: UInt64

    init(_ hold: CloudHomeState.EditHold) {
        inFlight = UInt64(max(hold.inFlight, 0))
        awaited = hold.awaited
        seen = hold.seen
    }
}

private nonisolated struct EchoHolds: Codable {
    var generation: UInt64
    var holds: [String: EchoHold]
    var viewed: [String]
}

private nonisolated enum EchoEvent: Encodable {
    case begin(conversation: String, generation: UInt64)
    case finish(conversation: String, generation: UInt64, committedAt: UInt64?, final: Bool)
    case echoed(conversation: String, rev: UInt64)
    case deadline(conversation: String, generation: UInt64)

    private enum Key: String, CodingKey { case kind, conversation, generation, committedAt, final, rev }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        switch self {
        case .begin(let conversation, let generation):
            try c.encode("begin", forKey: .kind)
            try c.encode(conversation, forKey: .conversation)
            try c.encode(generation, forKey: .generation)
        case .finish(let conversation, let generation, let committedAt, let final):
            try c.encode("finish", forKey: .kind)
            try c.encode(conversation, forKey: .conversation)
            try c.encode(generation, forKey: .generation)
            try c.encodeIfPresent(committedAt, forKey: .committedAt)
            try c.encode(final, forKey: .final)
        case .echoed(let conversation, let rev):
            try c.encode("echoed", forKey: .kind)
            try c.encode(conversation, forKey: .conversation)
            try c.encode(rev, forKey: .rev)
        case .deadline(let conversation, let generation):
            try c.encode("deadline", forKey: .kind)
            try c.encode(conversation, forKey: .conversation)
            try c.encode(generation, forKey: .generation)
        }
    }
}

private nonisolated struct EchoStepRequest: Encodable {
    var state: EchoHolds
    var event: EchoEvent
}

private nonisolated enum EchoEffect: Decodable {
    case cancelDeadline
    case scheduleDeadline(afterMs: Int64)
    case endSubscription

    private enum Key: String, CodingKey { case kind, afterMs }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "cancelDeadline": self = .cancelDeadline
        case "scheduleDeadline": self = .scheduleDeadline(afterMs: try c.decode(Int64.self, forKey: .afterMs))
        case "endSubscription": self = .endSubscription
        case let kind: throw DecodingError.dataCorruptedError(forKey: .kind, in: c, debugDescription: "effect \(kind)")
        }
    }
}

private nonisolated struct EchoStepReply: Decodable {
    var state: EchoHolds
    var effects: [EchoEffect]
}
