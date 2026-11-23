/// Decides when a connected transport that has gone quiet should be asked whether it is still
/// there, and when its silence means it is gone.
///
/// A transport normally dies with its link, and the end of its stream starts a reconnect. Some do
/// not. A broker that keeps retrying a refused connection holds its process and its local pipe
/// open, so the mirror receives neither bytes nor an exit and stays frozen while it still counts
/// as connected. Nothing local marks that silence, so after ``probeAfterSilence`` with no stdout
/// the connection sends ``probeCommand``. Any stdout at all answers it. If none arrives within
/// ``probeReplyDeadline``, the transport is treated as dropped.
///
/// The probe is what declares a stall, never a count of outstanding commands, so a reply slot
/// that was never answered cannot make a quiet but healthy session reconnect.
public struct RemoteTmuxTransportLiveness: Equatable, Sendable {
    /// How long stdout may stay silent before the connection asks.
    public static let probeAfterSilence: Duration = .seconds(30)
    /// How long the probe may go unanswered before the transport counts as dropped.
    public static let probeReplyDeadline: Duration = .seconds(30)
    /// `display-message -p` writes its format into the command's reply and changes nothing on
    /// the server. The empty format keeps that reply to one empty line.
    public static let probeCommand = "display-message -p ''"

    public enum Decision: Equatable, Sendable {
        case wait(until: ContinuousClock.Instant)
        case probe
        case stall(silentFor: Duration)
    }

    /// When the transport last wrote to stdout.
    public private(set) var lastStdoutAt: ContinuousClock.Instant?
    /// When the unanswered probe was sent. Cleared by any stdout.
    public private(set) var probeSentAt: ContinuousClock.Instant?

    public init() {}

    public mutating func noteStdout(at now: ContinuousClock.Instant) {
        lastStdoutAt = now
        probeSentAt = nil
    }

    public mutating func noteProbeSent(at now: ContinuousClock.Instant) {
        probeSentAt = now
    }

    public func decide(now: ContinuousClock.Instant) -> Decision {
        guard let lastStdoutAt else { return .wait(until: now + Self.probeAfterSilence) }
        if let probeSentAt {
            let due = probeSentAt + Self.probeReplyDeadline
            return now >= due ? .stall(silentFor: lastStdoutAt.duration(to: now)) : .wait(until: due)
        }
        let due = lastStdoutAt + Self.probeAfterSilence
        return now >= due ? .probe : .wait(until: due)
    }
}
