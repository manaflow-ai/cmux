public import CmuxNextMobile
public import Foundation
public import Observation

/// What the phone listener is doing right now, for the Mobile Pairing page:
/// its phase (nil while no listener exists) and the phones that became usable
/// since it started. ``MobileHostService`` keeps it current.
@MainActor
@Observable
public final class MobileHostStatus {
    /// The running listener's phase; nil while signed out, while phone access is off, or between listeners.
    public internal(set) var phase: MobileIrxHost.Phase?
    /// Phone connections that became usable since the current listener started.
    public internal(set) var connectedPhones = 0
    /// When the last phone connection became usable.
    public internal(set) var lastPhoneAt: Date?

    public init() {}

    /// A new listener (or none): its phones are its own.
    func reset() {
        phase = nil
        connectedPhones = 0
        lastPhoneAt = nil
    }

    func phoneBecameUsable(at date: Date) {
        connectedPhones += 1
        lastPhoneAt = date
    }
}
