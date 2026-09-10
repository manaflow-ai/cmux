import Foundation

/// Outcome of decoding the private terminal-to-surface resolver response.
enum CloudTuiResolvedSurface: Equatable, Sendable {
    case surface(UInt64)
    case noPlacement
    /// The remote shell is gone: the daemon reports the terminal as exited, or
    /// no longer has a record for it. A pane showing it must close, the way a
    /// local pane closes when its shell exits.
    case exited
    case malformed
}
