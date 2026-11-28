import Foundation

/// Whether a Mac is there, the one answer every screen reads (Home, a Mac's Home, Chief and its
/// settings, terminal tabs). It comes from this phone's link to the Mac (``AppStore/macConnection``)
/// and the service's presence (``MacDevice/isOnline``), in one place, so no screen keeps its own
/// copy that can say the Mac is offline while the link is up.
///
/// Leo, relaying Aziz (2026-11-28, ask-02dd2cc9ee): "im also getting this in several screens
/// despite my mac being connected (ik because gui works)".
public enum MacPresence: Equatable, Sendable {
    /// Macs are not tracked live (mock mode, a demo), or no Mac is named: no screen says anything.
    case untracked
    /// This phone's link to the Mac is up.
    case up
    /// The link is dialing or redialing.
    case coming
    /// The link is neither up nor coming. `listedOnline`: the service's presence for the Mac
    /// (nil: the Mac is not in the account's list).
    case down(listedOnline: Bool?)

    public var isUp: Bool { self == .up }

    /// The link is down (not up, not dialing).
    public var isDown: Bool {
        if case .down = self { return true }
        return false
    }

    /// The only state in which a screen may say the Mac is offline: the link is down and the
    /// service says so too. A Mac whose link is up is never offline, whatever presence says.
    public var isMacOffline: Bool { self == .down(listedOnline: false) }
}

extension AppStore {
    /// The Mac's ``MacPresence``: what every screen reads to say whether the Mac is there.
    public func macPresence(_ macID: String?) -> MacPresence {
        guard tracksMacData, let macID, !macID.isEmpty else { return .untracked }
        switch macConnection[macID] {
        case .connected: return .up
        case .connecting: return .coming
        case .failed, nil:
            let mac = activeTeam?.macs.first { $0.id == macID }
            return .down(listedOnline: mac?.isOnline)
        }
    }
}
