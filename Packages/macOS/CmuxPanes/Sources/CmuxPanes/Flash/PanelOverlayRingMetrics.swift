public import CoreGraphics

/// The fixed geometry of a panel focus/attention overlay ring.
///
/// The ring path is inset from the overlay bounds by ``inset`` and stroked with
/// ``lineWidth`` at corner radius ``cornerRadius``. These constants are the
/// single source of truth shared by the attention-flash presentation and the
/// overlay views that draw the ring.
public enum PanelOverlayRingMetrics {
    public static let inset: CGFloat = 2
    public static let cornerRadius: CGFloat = 6
    public static let lineWidth: CGFloat = 2.5

    /// The ring path rect inset from `bounds`.
    public static func pathRect(in bounds: CGRect) -> CGRect {
        bounds.insetBy(dx: inset, dy: inset)
    }
}
