#if canImport(UIKit)
import QuartzCore

/// Main-actor snapshot used to reject a frozen-frame copy when layer identity
/// or geometry changes while immutable pixels are copied off-main.
@MainActor
struct VerifiedReplayFrozenRendererSnapshot {
    let renderer: CALayer?
    let contents: Any?
    let identity: VerifiedReplayRendererSurfaceIdentity?
    let geometry: VerifiedReplayPresentationGeometry?
    let geometryRevision: UInt64

    func matches(
        _ other: VerifiedReplayFrozenRendererSnapshot
    ) -> Bool {
        identity == other.identity
            && geometry == other.geometry
            && geometryRevision == other.geometryRevision
    }
}
#endif
