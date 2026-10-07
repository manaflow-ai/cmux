public import CmuxRemoteDesktop

/// What a target reports while it runs.
public enum RemoteDesktopTargetEvent: Hashable, Sendable {
    /// The target's size changed (VNC ServerInit or DesktopSize, display mode change).
    case resized(DesktopTargetInfo)
    /// The VNC server wants a password.
    case authRequired
    /// Frames flow (after authentication, or after a pause).
    case live
    /// No frames for now (display asleep).
    case paused(reason: String)
    /// Clipboard text the target offered on its own (VNC ServerCutText).
    case clipboard(String)
    /// The target is gone; last event.
    case ended(DesktopEndReason)
}
