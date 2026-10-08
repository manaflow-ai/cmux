public import CMUXMobileCore

/// Decides whether a geometry pass needs to publish a natural-grid report.
///
/// A real capacity change must supersede an older in-flight report. A geometry
/// reassert for the same capacity is different: while a report is queued or
/// awaiting its echo, publishing it again creates a self-sustaining
/// negotiation loop.
public struct TerminalViewportReportPolicy: Sendable {
    private let naturalCapacityChangedValue: Bool
    private let shouldReassertNaturalSize: Bool
    private let effectiveGridExceedsNatural: Bool
    private let viewportReportPending: Bool

    /// Creates a report decision for the current and previous natural grids.
    ///
    /// - Parameters:
    ///   - naturalGrid: The capacity measured by the current geometry pass.
    ///   - previousNaturalGrid: The last capacity handed to the viewport reporter.
    ///   - shouldReassertNaturalSize: Whether the pass was explicitly asked to reassert capacity.
    ///   - effectiveGrid: The daemon's effective cell grid, if one has been
    ///     echoed. A smaller grid is an intentional shared-sizing constraint;
    ///     a grid larger than this phone's natural capacity is stale.
    ///   - viewportReportPending: Whether an equivalent report is queued or awaiting its echo.
    public init(
        naturalGrid: TerminalGridSize,
        previousNaturalGrid: TerminalGridSize?,
        shouldReassertNaturalSize: Bool,
        effectiveGrid: (columns: Int, rows: Int)?,
        viewportReportPending: Bool
    ) {
        // Pixel dimensions describe the rendered backing store, but the
        // viewport RPC negotiates only logical cell capacity. A pixel-only
        // change must not mint another report for the same grid.
        self.naturalCapacityChangedValue = previousNaturalGrid.map {
            naturalGrid.columns != $0.columns || naturalGrid.rows != $0.rows
        } ?? true
        self.shouldReassertNaturalSize = shouldReassertNaturalSize
        self.effectiveGridExceedsNatural = effectiveGrid.map {
            $0.columns > naturalGrid.columns || $0.rows > naturalGrid.rows
        } ?? false
        self.viewportReportPending = viewportReportPending
    }

    /// Whether this geometry pass should publish a natural-grid report.
    public var shouldReport: Bool {
        naturalCapacityChanged ||
            (shouldReassertNaturalSize && effectiveGridExceedsNatural && !viewportReportPending)
    }

    /// Whether the logical columns or rows differ from the previous natural capacity.
    public var naturalCapacityChanged: Bool {
        naturalCapacityChangedValue
    }
}
