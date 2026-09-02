import Foundation

/// One-based inclusive line range for selected native text.
public nonisolated struct SurfaceSelectionLineRange: Equatable, Sendable {
    /// First selected source line, using one-based indexing.
    public let start: Int

    /// Last selected source line, using one-based inclusive indexing.
    public let end: Int

    /// Creates a valid one-based inclusive source range.
    ///
    /// - Parameters:
    ///   - start: First selected line. Must be at least `1`.
    ///   - end: Last selected line. Must not precede `start`.
    public init?(start: Int, end: Int) {
        guard start >= 1, end >= start else { return nil }
        self.start = start
        self.end = end
    }
}
