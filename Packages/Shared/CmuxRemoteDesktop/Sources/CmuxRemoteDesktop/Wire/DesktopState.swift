/// Where a desktop session is, as the Mac reports it (`desktop.state`).
public enum DesktopState: String, Hashable, Sendable, CaseIterable {
    /// The person at the Mac has not answered the consent panel yet.
    case waitingConsent = "waiting_consent"
    /// The VNC server wants a password (`desktop.auth`).
    case authRequired = "auth_required"
    case live
    /// The target produces no frames for now (display asleep, window minimized).
    case paused
}
