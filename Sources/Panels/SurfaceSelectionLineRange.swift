import Foundation

/// One-based inclusive line range for selected native text.
public nonisolated struct SurfaceSelectionLineRange: Equatable, Sendable {
    public let start: Int
    public let end: Int

    public init(start: Int, end: Int) {
        self.start = start
        self.end = end
    }
}
