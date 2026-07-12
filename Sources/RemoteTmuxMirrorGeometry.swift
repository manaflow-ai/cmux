import Foundation

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
struct RemoteTmuxMirrorGeometry: Equatable, Sendable {
    /// Terminal cell width in device pixels (integer, from ghostty).
    let cellWidthPx: Int
    /// Terminal cell height in device pixels (integer, from ghostty).
    let cellHeightPx: Int
    /// Horizontal ghostty padding per surface in device pixels (both sides
    /// combined — the fixed part of `surface_px − cols·cell_px`).
    let surfacePadWidthPx: Int
    /// Vertical ghostty padding per surface in device pixels (both sides
    /// combined).
    let surfacePadHeightPx: Int
    /// The hosting window's backing scale (1.0 or 2.0 on macOS).
    let scale: CGFloat

    /// Floors below which a client size is never pushed: tmux clamps
    /// per-window at the layout minimum anyway (measured: no errors, no
    /// restructures down to 1×1), but a session-visible postage stamp from a
    /// transient degenerate frame is never useful.
    static let minCols = 20
    static let minRows = 5
}
