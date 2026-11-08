public import CoreGraphics
public import Darwin

/// SECURITY: the windows cmux's own screen captures leave out (screen sharing, `cmux rd serve`, its screen
/// recorders): every on-screen window of the app with `NSWindow.sharingType = .none`, such as the join
/// consent ask or a revealed password. That property only asks captures to skip a window: since macOS
/// 15.4 a ScreenCaptureKit capture may still show it, and another app's capture is not ours to control.
/// So every capture cmux makes reads this list and leaves these windows out by id.
///
/// Read from the window server (each window's sharing state), never kept: nothing registers, a window is
/// on the list while it shows with `.none`, and any thread may read it. A running capture reads it again
/// every ``recheck``.
public enum CaptureExcludedWindows {
    /// How often a running screen share reads the list again: the longest a newly shown window can take
    /// to leave it.
    public static let recheck: Duration = .milliseconds(250)

    /// The on-screen windows of process `pid` (this app's by default) that ask not to be shared.
    public static func windowIDs(of pid: pid_t = getpid()) -> Set<CGWindowID> {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return [] }
        return excluded(windows, of: pid)
    }

    /// The windows in `windows` (the window server's info dictionaries) of `pid` that ask not to be shared.
    static func excluded(_ windows: [[String: Any]], of pid: pid_t) -> Set<CGWindowID> {
        Set(windows.compactMap { info -> CGWindowID? in
            guard (info[kCGWindowOwnerPID as String] as? Int).map(pid_t.init) == pid,
                  (info[kCGWindowSharingState as String] as? Int).map(UInt32.init) == CGWindowSharingType.none.rawValue
            else { return nil }
            return (info[kCGWindowNumber as String] as? Int).map(CGWindowID.init)
        })
    }
}
