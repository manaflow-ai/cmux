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
        var cancel: (@Sendable () async -> Void)?
    }
    private let admission = Mutex(Admission())
    private struct Serving: Sendable {
        var on = false
        var period: UInt64 = 0
    }
    private let serving = Mutex(Serving())
    private let startsSessions: Mutex<Bool>
    /// Lowercase workspace keys of incognito workspaces (`setHiddenWorkspaces`).
    private let hidden = Mutex<Set<String>>([])

    public init(allowsStartingSessions: Bool = true) {
        startsSessions = Mutex(allowsStartingSessions)
    }

    /// Unwired and signed-out listeners fail closed.
    public func setAdmission(decide: @escaping @Sendable (MobileHostPairRequest) async -> Bool,
                             recheck: @escaping @Sendable (MobileHostPairRequest) -> Bool,
                             cancel: (@Sendable () async -> Void)? = nil) {
        admission.withLock { $0 = Admission(decide: decide, recheck: recheck, cancel: cancel) }
    }

    /// The current serving period while Phone Access is on and signed in, else nil.
    /// Every turn on or off starts a new period, so an answer given in an earlier one
    /// can't save, and turning off also closes the questions still open.
    public var servingPeriod: UInt64? { serving.withLock { $0.on ? $0.period : nil } }

    public func setServing(_ on: Bool) {
        let turnedOff = serving.withLock { serving -> Bool in
            guard serving.on != on else { return false }
            serving.on = on
            serving.period &+= 1
            return !on
        }
        guard turnedOff, let cancel = admission.withLock({ $0.cancel }) else { return }
        // task-owner: one hop that closes this Mac's open admission questions; ends at once
        Task { await cancel() }
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

    /// Incognito workspaces (leo-workspace design/spaces.md "Incognito"): a phone never lists one, and a
    /// request naming one (or one of its terminals) is answered as if it did not exist. The app sets every
    /// incognito workspace's key here whenever its incognito windows change (`WindowManager`).
    public func setHiddenWorkspaces(_ keys: Set<String>) {
        let lowered = Set(keys.map { $0.lowercased() })
        hidden.withLock { $0 = lowered }
    }

    /// Whether workspace key `key` is an incognito workspace's, which no phone may see.
    public func hidesWorkspace(_ key: String) -> Bool {
        let key = key.lowercased()
        return hidden.withLock { $0.contains(key) }
    }

    /// The message a phone gets for a request that would start a workspace or terminal.
    public static let startRefusal = "starting new workspaces from a phone is turned off on this Mac"
}
