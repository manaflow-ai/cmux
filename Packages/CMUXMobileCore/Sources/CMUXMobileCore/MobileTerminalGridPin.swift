import Foundation

/// The authoritative terminal grid (in character cells) the phone should pin
/// its local libghostty surface to, paired with the geometry generation that
/// produced it.
///
/// Unlike ``TerminalGridSize`` (which also carries pixel extents measured on a
/// specific device), this is purely the cell grid the Mac is rendering at. It
/// is the value carried on every render-grid frame (``columns``/``rows``) and
/// returned by the viewport RPC, so the phone can letterbox its own render to
/// match the shared grid without re-measuring.
public struct MobileTerminalGridPin: Equatable, Hashable, Sendable {
    /// The number of character columns the Mac is rendering at.
    public var columns: Int
    /// The number of character rows the Mac is rendering at.
    public var rows: Int
    /// The grid generation (the Mac's ``MobileTerminalRenderGridFrame/geometryGen``)
    /// that carried this grid. Used to order geometry across the phone's two
    /// channels (the ordered render-grid frame stream and the out-of-band
    /// viewport RPC reply): an older generation can never overwrite a newer
    /// grid. It advances exactly when the Mac's exported grid changes, which a
    /// byte sequence cannot do (that does not advance on a pure resize).
    public var geometrySeq: UInt64

    /// Creates a grid pin.
    /// - Parameters:
    ///   - columns: The number of character columns the Mac is rendering at.
    ///   - rows: The number of character rows the Mac is rendering at.
    ///   - geometrySeq: The grid generation that carried this grid.
    public init(columns: Int, rows: Int, geometrySeq: UInt64) {
        self.columns = columns
        self.rows = rows
        self.geometrySeq = geometrySeq
    }
}
