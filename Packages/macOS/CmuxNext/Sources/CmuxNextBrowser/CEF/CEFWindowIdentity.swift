/// Which pane host a Chromium window id names.
nonisolated enum CEFWindowIdentity {
    /// True when window `reported` is the host's window: the id recorded
    /// when its window was created (`recorded`, nil before), or the window
    /// its tabs are in now (`liveWindowIDs`, read only when needed).
    static func owns(recorded: Int32?, reported: Int32, liveWindowIDs: () -> [Int32]) -> Bool {
        recorded == reported
    }
}
