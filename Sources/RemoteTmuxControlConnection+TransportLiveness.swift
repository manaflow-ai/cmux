import Foundation

/// Placeholder for transport liveness: records stdout and never decides anything.
struct RemoteTmuxTransportLiveness {
    static let probeAfterSilence: Duration = .seconds(30)
    static let probeReplyDeadline: Duration = .seconds(30)
    static let probeCommand = "display-message -p ''"

    enum Decision: Equatable {
        case wait(until: ContinuousClock.Instant)
        case probe
        case stall(silentFor: Duration)
    }

    private(set) var lastStdoutAt: ContinuousClock.Instant?
    private(set) var probeSentAt: ContinuousClock.Instant?
    var now: () -> ContinuousClock.Instant = { .now }

    func decide(now: ContinuousClock.Instant) -> Decision {
        .wait(until: now + Self.probeAfterSilence)
    }
}

extension RemoteTmuxControlConnection {
    func noteTransportStdout() {
        lastTransportOutputAt = .now
    }

    @discardableResult
    func checkTransportLiveness(now: ContinuousClock.Instant) -> RemoteTmuxTransportLiveness.Decision {
        transportLiveness.decide(now: now)
    }
}
