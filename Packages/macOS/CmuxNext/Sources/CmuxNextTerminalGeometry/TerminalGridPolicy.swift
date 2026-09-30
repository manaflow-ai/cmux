/// Which grid one terminal surface renders and which grid it reports.
///
/// Two grids meet here: the grid the view's pixel size fits (`desired`) and
/// the grid the PTY owner announced (`announced`, a `.resize` event in
/// stream order). A mirror must render the PTY's grid at every point in the
/// byte stream, or output lands in the wrong cells.
///
/// This models the policy `TerminalSurfaceView` applies. An owner renders
/// its own view grid as soon as the view changes and treats an announced
/// grid it reported earlier as a late echo.
public nonisolated struct TerminalGridPolicy: Sendable {
    /// Whether this view's size is reported to the PTY owner.
    public var ownsGeometry: Bool
    /// Latest grid the PTY owner announced.
    public private(set) var announced: TerminalGridSize?
    /// Latest grid the view's pixel size fits.
    public private(set) var desired: TerminalGridSize?
    /// Last grid reported to the PTY owner.
    public private(set) var reported: TerminalGridSize?
    /// Grid the surface renders.
    public private(set) var rendered: TerminalGridSize?
    private var recentReports: [TerminalGridSize] = []

    public init(ownsGeometry: Bool) {
        self.ownsGeometry = ownsGeometry
    }

    /// The view now fits `grid`. Returns the grid to report, if any.
    public mutating func viewSized(_ grid: TerminalGridSize, force: Bool = false) -> TerminalGridSize? {
        desired = grid
        guard ownsGeometry else {
            rendered = announced ?? grid
            return nil
        }
        rendered = grid
        guard force || grid != reported else { return nil }
        reported = grid
        recentReports.removeAll { $0 == grid }
        recentReports.append(grid)
        if recentReports.count > 4 { recentReports.removeFirst() }
        return grid
    }

    /// The PTY owner announced `grid` at this point in the stream.
    public mutating func announce(_ grid: TerminalGridSize) {
        announced = grid
        guard ownsGeometry else {
            rendered = grid
            return
        }
        if let index = recentReports.firstIndex(of: grid), index < recentReports.count - 1 {
            recentReports.removeFirst(index + 1)
            return
        }
        rendered = grid == desired ? desired : grid
    }
}
