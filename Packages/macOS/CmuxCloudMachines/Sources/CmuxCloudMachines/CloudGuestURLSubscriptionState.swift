/// Bounded recovery for an optional guest URL subscription. Recovery is driven
/// by authoritative link progress, never a polling timer or metadata count.
public struct CloudGuestURLSubscriptionState: Sendable {
    private enum Phase { case running, disconnected, unavailable }
    private var phase = Phase.running
    private var recoveries = 0

    /// Starts a new connection scope with two automatic recovery attempts.
    public init() {}

    /// CLI exit 1 is a protocol rejection and 2 is unsupported CLI syntax.
    /// Other exits may recover after the ordinary session feed makes progress.
    public mutating func ended(exitCode: Int32) {
        phase = (exitCode == 1 || exitCode == 2) ? .unavailable : .disconnected
    }

    /// Claims one recovery attempt; repeated metadata events cannot restart an
    /// active stream or spin on an older daemon that lacks this protocol.
    public mutating func recoverOnLinkProgress() -> Bool {
        guard phase == .disconnected, recoveries < 2 else { return false }
        recoveries += 1
        phase = .running
        return true
    }
}
