/// The TCC permissions remote desktop depends on.
public enum RemoteDesktopPermission: String, Hashable, Sendable, CaseIterable {
    /// Needed to capture displays and windows.
    case screenRecording = "screen_recording"
    /// Needed to inject pointer and keys (control mode).
    case accessibility
}
