import CmuxNextCompat

/// What phones may do on this Mac right now (Settings > Accounts > Phone
/// Access), read per request by whatever serves the phone. It names no
/// transport: the Iroh host (`MobileIrxHost`) applies it today, and a
/// replacement transport applies the same gate, so the settings and the
/// rules do not move with the transport decision.
public final class PhoneAccessGate: Sendable {
    private let startsSessions: Mutex<Bool>

    public init(allowsStartingSessions: Bool = true) {
        startsSessions = Mutex(allowsStartingSessions)
    }

    /// `phone.startSessions`: a phone may create workspaces and terminals.
    /// Off, it can still list, follow, type into and close what runs.
    public var allowsStartingSessions: Bool {
        startsSessions.withLock { $0 }
    }

    public func setAllowsStartingSessions(_ allowed: Bool) {
        startsSessions.withLock { $0 = allowed }
    }

    /// The message a phone gets for a request that would start a workspace or terminal.
    public static let startRefusal = "starting new workspaces from a phone is turned off on this Mac"
}
