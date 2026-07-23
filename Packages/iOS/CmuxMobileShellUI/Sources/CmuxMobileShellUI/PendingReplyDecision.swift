/// The pure lifecycle decision for a parked inline notification reply.
enum PendingReplyDecision: Equatable, Sendable {
    case noPending
    case waiting
    case expired
    case ready(PendingReply)
}
