public import Foundation

/// Judges each request line a phone sends on a spliced lane before it
/// reaches a local daemon socket (cmux-tui's, acpmux's).
public protocol LaneLineAuthority: Sendable {
    /// The longest request line accepted from the phone.
    var maximumLineBytes: Int { get }
    /// Judges one newline-stripped request line.
    func evaluate(_ line: Data) -> DaemonLanePolicy.Verdict
}
