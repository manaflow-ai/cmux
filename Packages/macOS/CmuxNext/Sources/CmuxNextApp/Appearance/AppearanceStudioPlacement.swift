import CoreGraphics

/// Where the floating appearance studio opens, in screen coordinates: over
/// the window it customizes, at the top trailing corner of its content, so
/// most of the window stays visible as the preview. The user can move it
/// from there. Pure, so every case is tested without windows.
enum AppearanceStudioPlacement {
    static let width: CGFloat = 340
    static let preferredHeight: CGFloat = 620
    /// From the content's edges.
    static let gap: CGFloat = 12

    /// - Parameter content: The window's content layout rect (below the
    ///   titlebar), in screen coordinates.
    /// - Returns: The studio's frame, never larger than the content.
    static func frame(content: CGRect) -> CGRect {
        let inner = content.insetBy(dx: gap, dy: gap)
        let size = CGSize(width: max(0, min(width, inner.width)), height: max(0, min(preferredHeight, inner.height)))
        return CGRect(x: inner.maxX - size.width, y: inner.maxY - size.height, width: size.width, height: size.height)
    }
}
