import CmuxNextCompat

/// What phones may do on this Mac right now (Settings > Accounts > Phone
/// Access), read per request by whatever serves the phone. It names no
/// transport: the Iroh host (`MobileIrxHost`) applies it today, and a
/// replacement transport applies the same gate, so the settings and the
/// rules do not move with the transport decision.
public final class PhoneAccessGate: Sendable {
    private struct Admission: Sendable {
        var decide: (@Sendable (MobileHostPairRequest) async -> Bool)?
        var recheck: (@Sendable (MobileHostPairRequest) -> Bool)?
    }
    private let admission = Mutex(Admission())
    private let startsSessions: Mutex<Bool>

    public init(allowsStartingSessions: Bool = true) {
        startsSessions = Mutex(allowsStartingSessions)
    }

    /// Unwired and signed-out listeners fail closed.
    public func setAdmission(decide: @escaping @Sendable (MobileHostPairRequest) async -> Bool,
                             recheck: @escaping @Sendable (MobileHostPairRequest) -> Bool) {
        admission.withLock { $0 = Admission(decide: decide, recheck: recheck) }
    }
    public func admits(_ phone: MobileHostPairRequest) async -> Bool {
        guard let decide = admission.withLock({ $0.decide }) else { return false }
        return await decide(phone)
    }
    public func stillAllows(_ phone: MobileHostPairRequest) -> Bool {
        admission.withLock { $0.recheck }?(phone) ?? false
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
