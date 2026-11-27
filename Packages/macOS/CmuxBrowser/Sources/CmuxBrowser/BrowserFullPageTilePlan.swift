public import CoreGraphics

/// A bounded, lazily-addressed tile grid for full-page browser screenshots.
public struct BrowserFullPageTilePlan: Equatable, Sendable {
    /// Largest number of sequential WebKit snapshots allowed for one full-page capture.
    public static let maximumTileCount = 128

    /// Full page dimensions in CSS pixels.
    public let contentSize: CGSize

    /// Visible viewport dimensions in CSS pixels.
    public let viewportSize: CGSize

    /// Number of horizontal tiles.
    public let columnCount: Int

    /// Number of vertical tiles.
    public let rowCount: Int

    /// Total number of WebKit snapshots in the plan.
    public let tileCount: Int

    /// Creates a plan when the required number of sequential captures is bounded.
    ///
    /// - Parameters:
    ///   - contentSize: Full page dimensions in CSS pixels.
    ///   - viewportSize: Visible viewport dimensions in CSS pixels.
    ///   - maximumTileCount: Largest permitted number of snapshots.
    public init?(
        contentSize: CGSize,
        viewportSize: CGSize,
        maximumTileCount: Int = Self.maximumTileCount
    ) {
        guard Self.isValid(contentSize),
              Self.isValid(viewportSize),
              maximumTileCount > 0,
              let columnCount = Self.tileCount(
                  contentLength: contentSize.width,
                  viewportLength: viewportSize.width,
                  maximumTileCount: maximumTileCount
              ),
              let rowCount = Self.tileCount(
                  contentLength: contentSize.height,
                  viewportLength: viewportSize.height,
                  maximumTileCount: maximumTileCount
              ),
              columnCount <= maximumTileCount / rowCount else {
            return nil
        }

        self.contentSize = contentSize
        self.viewportSize = viewportSize
        self.columnCount = columnCount
        self.rowCount = rowCount
        tileCount = columnCount * rowCount
    }

    /// Returns one tile's scroll origin without materializing the full origin grid.
    ///
    /// - Parameters:
    ///   - column: Zero-based horizontal tile index.
    ///   - row: Zero-based vertical tile index.
    /// - Returns: The CSS-pixel scroll origin, or `nil` for an out-of-range index.
    public func origin(column: Int, row: Int) -> CGPoint? {
        guard 0..<columnCount ~= column,
              0..<rowCount ~= row else {
            return nil
        }
        return CGPoint(
            x: Self.origin(
                index: column,
                contentLength: contentSize.width,
                viewportLength: viewportSize.width
            ),
            y: Self.origin(
                index: row,
                contentLength: contentSize.height,
                viewportLength: viewportSize.height
            )
        )
    }

    private static func isValid(_ size: CGSize) -> Bool {
        size.width.isFinite && size.height.isFinite && size.width > 0 && size.height > 0
    }

    private static func tileCount(
        contentLength: Double,
        viewportLength: Double,
        maximumTileCount: Int
    ) -> Int? {
        let count = max(1, (contentLength / viewportLength).rounded(.up))
        guard count.isFinite, count <= Double(maximumTileCount) else { return nil }
        return Int(count)
    }

    private static func origin(
        index: Int,
        contentLength: Double,
        viewportLength: Double
    ) -> Double {
        min(
            Double(index) * viewportLength,
            max(0, contentLength - viewportLength)
        )
    }
}
