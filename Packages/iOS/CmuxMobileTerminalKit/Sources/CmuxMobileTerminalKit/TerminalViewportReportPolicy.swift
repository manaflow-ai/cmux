import CMUXMobileCore

/// Decides whether a geometry pass needs to publish a natural-grid report.
///
/// A real capacity change must supersede an older in-flight report. A geometry
/// reassert for the same capacity is different: while a report is queued or
/// awaiting its echo, publishing it again creates a self-sustaining
/// negotiation loop.
public struct TerminalViewportReportPolicy: Sendable {
    private let naturalCapacityChanged: Bool
    private let shouldReassertNaturalSize: Bool
    private let effectiveMatchesNatural: Bool
    private let viewportReportPending: Bool

    public init(
        naturalGrid: TerminalGridSize,
        previousNaturalGrid: TerminalGridSize?,
        shouldReassertNaturalSize: Bool,
        effectiveMatchesNatural: Bool,
        viewportReportPending: Bool
    ) {
        // RED baseline: this currently treats pixel-only drift as a new grid.
        // The follow-up fix must compare the logical cell capacity only.
        self.naturalCapacityChanged = naturalGrid != previousNaturalGrid
        self.shouldReassertNaturalSize = shouldReassertNaturalSize
        self.effectiveMatchesNatural = effectiveMatchesNatural
        self.viewportReportPending = viewportReportPending
    }

    public var shouldReport: Bool {
        naturalCapacityChanged ||
            (shouldReassertNaturalSize && !effectiveMatchesNatural && !viewportReportPending)
    }
}
