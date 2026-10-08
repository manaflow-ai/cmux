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
    private let effectiveMatchesNatural: Bool
    private let viewportReportPending: Bool

    /// Creates a report decision for the current and previous natural grids.
    ///
    /// - Parameters:
    ///   - naturalGrid: The capacity measured by the current geometry pass.
    ///   - previousNaturalGrid: The last capacity handed to the viewport reporter.
    ///   - shouldReassertNaturalSize: Whether the pass was explicitly asked to reassert capacity.
    ///   - effectiveMatchesNatural: Whether the daemon's effective cell grid matches this pass.
    ///   - viewportReportPending: Whether an equivalent report is queued or awaiting its echo.
    public init(
        naturalGrid: TerminalGridSize,
        previousNaturalGrid: TerminalGridSize?,
        shouldReassertNaturalSize: Bool,
        effectiveMatchesNatural: Bool,
        viewportReportPending: Bool
    ) {
        // Pixel dimensions describe the rendered backing store, but the
        // viewport RPC negotiates only logical cell capacity. A pixel-only
        // change must not mint another report for the same grid.
        self.naturalCapacityChangedValue = previousNaturalGrid.map {
            naturalGrid.columns != $0.columns || naturalGrid.rows != $0.rows
        } ?? true
        self.shouldReassertNaturalSize = shouldReassertNaturalSize
        self.effectiveMatchesNatural = effectiveMatchesNatural
        self.viewportReportPending = viewportReportPending
    }

    /// Whether this geometry pass should publish a natural-grid report.
    public var shouldReport: Bool {
        naturalCapacityChanged ||
            (shouldReassertNaturalSize && !effectiveMatchesNatural && !viewportReportPending)
    }

    /// Whether the logical columns or rows differ from the previous natural capacity.
    public var naturalCapacityChanged: Bool {
        naturalCapacityChangedValue
    }
}
