public import CoreGraphics

/// Stroke width shared by the pane focus and attention indicators: the active
/// pane border, the notification ring, the focus flash and the Canvas focus
/// border. They draw along the same edge, so one width keeps them aligned.
public enum PaneIndicatorMetrics {
    public static let strokeWidth: CGFloat = 2
}
