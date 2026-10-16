public import CoreGraphics

extension CGFloat {
    /// Stroke width shared by the pane focus and attention indicators: the active
    /// pane border, the notification ring, the focus flash and the Canvas focus
    /// border. They draw along the same edge, so one width keeps them aligned.
    public static let paneIndicatorStrokeWidth: CGFloat = 2
}
