public import Foundation

/// A movie's length as a player shows it: `0:07`, `1:02`, `1:02:03`.
public nonisolated struct FileGridDurationText: Sendable {
    /// Makes the formatter.
    public init() {}

    /// The length text.
    ///
    /// - Parameter seconds: the movie's length.
    public func string(for seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let rest = total % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, rest) : String(format: "%d:%02d", minutes, rest)
    }
}
