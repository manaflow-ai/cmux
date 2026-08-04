import CoreGraphics
import Foundation

/// Identifies the visible terminal cell whose command-hover resolution is cached.
///
/// Command-click routing deliberately resolves again, so terminal output changing
/// under a stationary pointer cannot open stale data.
struct WordPathHoverCacheKey: Equatable {
    let surfaceID: UUID
    let surfaceGeneration: UInt64
    let renderedFrameGeneration: UInt64
    let row: Int
    let column: Int
    let rows: Int
    let columns: Int
    let boundsSize: CGSize
    let cellSize: CGSize
    let workingDirectory: String
}
