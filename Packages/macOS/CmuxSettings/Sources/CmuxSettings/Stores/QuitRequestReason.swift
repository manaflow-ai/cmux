import CoreServices

/// Why the app was asked to quit, read from the quit Apple Event or set by the updater.
///
/// macOS sends logout, restart, and shutdown as a quit event whose
/// `kAEQuitReason` attribute names the session change. A confirmation dialog
/// shown then blocks the whole session change, so those quits skip it. An
/// update relaunch skips it too: the user already chose Install and Relaunch.
public enum QuitRequestReason: Sendable, Equatable {
    /// Cmd+Q, the menu, the Dock, or any quit without a session-change reason.
    case user
    /// Logout, restart, or shutdown started by the system.
    case sessionEnd
    /// Sparkle is relaunching the app to finish installing an update.
    case updateRelaunch

    /// Maps the quit event's `kAEQuitReason` code. A missing or unknown code
    /// is an ordinary quit.
    public init(appleEventQuitReason code: OSType?) {
        switch code {
        case kAELogOut, kAEReallyLogOut,
             kAEShowRestartDialog, kAERestart,
             kAEShowShutdownDialog, kAEShutDown:
            self = .sessionEnd
        default:
            self = .user
        }
    }
}
