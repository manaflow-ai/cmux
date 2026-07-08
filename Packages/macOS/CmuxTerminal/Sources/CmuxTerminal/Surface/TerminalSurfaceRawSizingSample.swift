public import AppKit
public import Foundation

/// One raw sizing sample from a live surface (see
/// ``TerminalSurface/rawSizingSample()``). Top-level and `Sendable` so
/// diagnostics handlers can carry it off the main actor.
public struct TerminalSurfaceRawSizingSample: Sendable {
    public let columns: Int
    public let rows: Int
    public let cellWidthPx: Int
    public let cellHeightPx: Int
    public let surfaceWidthPx: Int
    public let surfaceHeightPx: Int
    public let viewBoundsPt: CGSize?
    public let backingScale: CGFloat?

    public init(
        columns: Int, rows: Int,
        cellWidthPx: Int, cellHeightPx: Int,
        surfaceWidthPx: Int, surfaceHeightPx: Int,
        viewBoundsPt: CGSize?, backingScale: CGFloat?
    ) {
        self.columns = columns
        self.rows = rows
        self.cellWidthPx = cellWidthPx
        self.cellHeightPx = cellHeightPx
        self.surfaceWidthPx = surfaceWidthPx
        self.surfaceHeightPx = surfaceHeightPx
        self.viewBoundsPt = viewBoundsPt
        self.backingScale = backingScale
    }
}
