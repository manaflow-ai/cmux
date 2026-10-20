import CmuxNextCompat

/// What phones may do on this Mac right now (Settings > Accounts > Phone
/// Access), read per request by whatever serves the phone. It names no
/// transport: the Iroh host (`MobileIrxHost`) applies it today, and a
/// replacement transport applies the same gate, so the settings and the
/// rules do not move with the transport decision.
public final class PhoneAccessGate: Sendable {
    private let startsSessions: Mutex<Bool>
    /// Decides whether a phone may use this Mac at all (`phone.newDevices`); nil admits every
    /// phone the transport's account check admitted.
    private let admission = Mutex<(@Sendable (PhoneDevice) async -> Bool)?>(nil)
    /// Whether a phone admitted a moment ago is still allowed (no question asked); nil allows.
    private let stillAllowed = Mutex<(@Sendable (String) -> Bool)?>(nil)

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

    public func setAdmission(_ decide: (@Sendable (PhoneDevice) async -> Bool)?,
                             stillAllowed check: (@Sendable (String) -> Bool)? = nil) {
        admission.withLock { $0 = decide }
        stillAllowed.withLock { $0 = check }
    }

    /// Whether the phone `id` (its endpoint key) is still allowed, without asking: false once removed.
    public func stillAllows(_ id: String) -> Bool {
        stillAllowed.withLock { $0 }?(id) ?? true
    }

    /// Whether `device` may use this Mac: on the allowed list, or the person allowed it now.
    public func admits(_ device: PhoneDevice) async -> Bool {
        guard let decide = admission.withLock({ $0 }) else { return true }
        return await decide(device)
    }

    /// The message a phone gets for a request that would start a workspace or terminal.
    public static let startRefusal = "starting new workspaces from a phone is turned off on this Mac"
}
