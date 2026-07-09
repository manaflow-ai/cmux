import Foundation

/// The output of ``RemoteTmuxMirrorGeometry/frames(layout:containerPt:)``:
/// exact per-pane frames and divider strips for one assigned layout, in points,
/// in the mirror container's coordinate space.
///
/// A value snapshot by design — the container view applies it verbatim and
/// holds no reference back to the geometry or the mirror, keeping the render
/// path free of observable-state reads inside `ForEach` rows.
struct RemoteTmuxMirrorFrames: Equatable, Sendable {
    /// Pane id → the exact frame its panel (header + terminal) occupies.
    let paneFramesPt: [Int: CGRect]
    /// Separator strips between siblings (one tmux cell wide/tall), painted
    /// as divider background.
    let dividersPt: [CGRect]
}
