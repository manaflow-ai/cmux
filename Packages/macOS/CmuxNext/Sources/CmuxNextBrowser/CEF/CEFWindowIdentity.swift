/// Which pane host a Chromium window id names.
nonisolated enum CEFWindowIdentity {
    /// True when window `reported` is the host's window: the id recorded
    /// when its window was created (`recorded`, nil before), or the window
    /// its tabs are in now (`liveWindowIDs`, read only when needed).
    /// Window 0 is no window (a popup Chromium has not placed yet): it
    /// names no host, even one whose id read 0 at creation.
    static func owns(recorded: Int32?, reported: Int32, liveWindowIDs: () -> [Int32]) -> Bool {
        guard reported != 0 else { return false }
        return recorded == reported || liveWindowIDs().contains(reported)
    }
}
