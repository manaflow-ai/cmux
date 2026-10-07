import CmuxTerminalStream

/// What a daemon attach delivers, in order.
public enum MobileTerminalEvent: Hashable, Sendable {
    /// A `terminal-snapshot-v1` frame: bytes, READY (keyframe), HISTORY or digest.
    case frame(TerminalFrame)
    /// The canonical grid changed (new generation).
    case size(generation: UInt32, cols: Int, rows: Int)
    case title(String, cwd: String?)
    case exited(code: Int?, signal: String?)
    /// Another client kicked this viewer.
    case kicked(by: String, byName: String)
    /// The attach ended (daemon gone or terminal reaped). Last event.
    case closed
}
