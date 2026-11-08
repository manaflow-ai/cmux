public import Foundation

/// The measured render constants for mirrored tmux windows: terminal cell
/// size, the ghostty surface padding, and the backing scale, as sampled from
/// a live surface (`ghostty_surface_size`). ``RemoteTmuxWindowMirror``
/// ingests sizing samples into one of these snapshots, and
/// ``RemoteTmuxNativeLayoutMetrics`` converts it to point-space metrics for
/// the claim and divider math.
///
/// Constants are measured, not assumed (calibrated 2026-07-03:
/// `cols == floor((surface_px − pad_w)/cell_px)` exact on 100% of settled
/// samples, pad_w = 8 device px at 2× with the default ghostty config,
/// pad_h = 0; `surface_px == view_pt × scale` exact).
public struct RemoteTmuxMirrorGeometry: Equatable, Sendable {
    /// Terminal cell width in device pixels (integer, from ghostty).
    public let cellWidthPx: Int
    /// Terminal cell height in device pixels (integer, from ghostty).
    public let cellHeightPx: Int
    /// Horizontal ghostty padding per surface in device pixels (both sides
    /// combined — the fixed part of `surface_px − cols·cell_px`).
    public let surfacePadWidthPx: Int
    /// Vertical ghostty padding per surface in device pixels (both sides
    /// combined).
    public let surfacePadHeightPx: Int
    /// The hosting window's backing scale (1.0 or 2.0 on macOS).
    public let scale: CGFloat

    /// Creates a measured geometry snapshot.
    public init(
        cellWidthPx: Int,
        cellHeightPx: Int,
        surfacePadWidthPx: Int,
        surfacePadHeightPx: Int,
        scale: CGFloat
    ) {
        self.cellWidthPx = cellWidthPx
        self.cellHeightPx = cellHeightPx
        self.surfacePadWidthPx = surfacePadWidthPx
        self.surfacePadHeightPx = surfacePadHeightPx
        self.scale = scale
    }

    /// Floors below which a client size is never pushed: tmux clamps
    /// per-window at the layout minimum anyway (measured: no errors, no
    /// restructures down to 1×1), but a session-visible postage stamp from a
    /// transient degenerate frame is never useful.
    public static let minCols = 20
    public static let minRows = 5
}
