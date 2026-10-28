import Foundation

/// Ends a local process for Kill Process. The App uses
/// ``SystemProcessSignaler``; tests may pass a recorder.
public protocol ProcessSignaling {
    /// Asks `pid` to end (SIGTERM). Returns false when no signal was sent.
    func terminate(_ pid: Int32) -> Bool
}
