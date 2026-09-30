/// Describes the state transition caused by a committed drawable geometry.
struct TerminalRendererPresentationReadinessDecision: Equatable, Sendable {
    let geometryChanged: Bool
    let shouldAwaitFrame: Bool

    /// Computes whether a new geometry can reopen presentation recovery.
    init(
        previous: TerminalRendererPresentationGeometry?,
        current: TerminalRendererPresentationGeometry,
        renderHealth: TerminalSurfaceRenderHealth,
        hasInFlightToken: Bool
    ) {
        geometryChanged = previous != current
        shouldAwaitFrame = geometryChanged
            && !hasInFlightToken
            && renderHealth != .shellExited
    }
}
