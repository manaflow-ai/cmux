/// Decides whether a geometry pass needs to publish a natural-grid report.
///
/// A real capacity change must supersede an older in-flight report. A geometry
/// reassert for the same capacity is different: while a report is queued or
/// awaiting its echo, publishing it again creates a self-sustaining
/// negotiation loop.
public struct TerminalViewportReportPolicy: Sendable {
    private let naturalGridChanged: Bool
    private let shouldReassertNaturalSize: Bool
    private let effectiveMatchesNatural: Bool
    private let viewportReportPending: Bool

    public init(
        naturalGridChanged: Bool,
        shouldReassertNaturalSize: Bool,
        effectiveMatchesNatural: Bool,
        viewportReportPending: Bool
    ) {
        self.naturalGridChanged = naturalGridChanged
        self.shouldReassertNaturalSize = shouldReassertNaturalSize
        self.effectiveMatchesNatural = effectiveMatchesNatural
        self.viewportReportPending = viewportReportPending
    }

    public var shouldReport: Bool {
        naturalGridChanged ||
            (shouldReassertNaturalSize && !effectiveMatchesNatural && !viewportReportPending)
    }
}
