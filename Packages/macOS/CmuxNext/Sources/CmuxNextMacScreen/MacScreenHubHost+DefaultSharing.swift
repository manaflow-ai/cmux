import CmuxNextDevices
import Foundation

/// Sharing on by default (Leo, 2026-11-16: "if you have indeed connected a machine, you should be able
/// to just screen share onto it freely"). A Mac signed in to the account with Screen Recording granted
/// turns its hub bit (`mac_screen_shared`) on by itself, so the account's other devices can view it with
/// nobody at it. It stays off when the person turned it off here (MacScreenStore), and goes off while
/// the grant is missing, without counting as the person's choice, so it comes back once granted.
/// Nothing here asks for a permission: the grant is requested once at join (`cmux share prepare`).
extension MacScreenHubHost {
    /// What the default does next.
    public enum DefaultSharingStep: Equatable, Sendable {
        case none, turnOn, turnOff
    }

    /// This Mac's sharing as the machine record shows it.
    public enum SharingState: String, Equatable, Sendable {
        case on
        case off
        /// The person turned it off here; it stays off until they turn it on.
        case turnedOff = "turned_off"
        /// macOS has no Screen Recording grant for this Mac's capture, so nothing can be shared.
        case needsGrant = "needs_grant"
    }

    /// The default's next step. `shared` is nil before the hub lists this Mac, `turnedOff` before the
    /// store is read, and `grantKnown` is false until a permission read answers: each of those waits.
    nonisolated static func defaultSharingStep(shared: Bool?, grantKnown: Bool, screenRecording: Bool,
                                               turnedOff: Bool?) -> DefaultSharingStep {
        guard let shared, grantKnown, let turnedOff else { return .none }
        if shared && !screenRecording { return .turnOff }
        if !shared && screenRecording && !turnedOff { return .turnOn }
        return .none
    }

    nonisolated static func sharingState(shared: Bool, grantKnown: Bool, screenRecording: Bool, turnedOff: Bool) -> SharingState {
        if grantKnown && !screenRecording { return .needsGrant }
        if shared { return .on }
        return turnedOff ? .turnedOff : .off
    }

    /// The step for this Mac now (observable: the hub's record, the grant, the person's switch).
    var defaultSharingStep: DefaultSharingStep {
        Self.defaultSharingStep(shared: hub()?.thisDevice?.macScreenShared, grantKnown: share.permissionsKnown,
                                screenRecording: share.screenRecordingGranted, turnedOff: sharingTurnedOff())
    }

    /// This Mac's sharing state (`debug.device_hub`'s `sharing_state`).
    public var sharingState: SharingState {
        Self.sharingState(shared: isSharing, grantKnown: share.permissionsKnown, screenRecording: share.screenRecordingGranted,
                          turnedOff: sharingTurnedOff() ?? false)
    }

    /// Takes the default's step now, once: no prompt and no permission request. A failed write leaves
    /// `lastError` and waits for the next change.
    func followDefaultSharing() async {
        guard !busy else { return }
        let step = defaultSharingStep
        guard step != .none else { return }
        try? await setSharing(step == .turnOn, requestPermissions: false, byPerson: false)
    }
}
