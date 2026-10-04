public import CmuxAgentCursor
public import CoreGraphics

/// Pure mapping from an `automation.input` event to overlay coordinates.
public enum AgentCursorGeometry {
    /// The page point the input lands on: `point`, else the center of
    /// `rect` (type and key may carry only the focused element), else nil.
    public static func pagePoint(of event: AutomationInputEvent) -> CGPoint? {
        if let point = event.point {
            return CGPoint(x: point.x, y: point.y)
        }
        if let rect = event.rect {
            return CGPoint(x: rect.x + rect.w / 2, y: rect.y + rect.h / 2)
        }
        return nil
    }

    /// Viewport CSS px times `(event zoom ?? page zoom) * magnification`,
    /// offset by the content origin, clamped into `clip` (the visible part of
    /// the viewport) so the cursor never lands on a docked column or a
    /// neighboring pane.
    public static func overlayPoint(
        of event: AutomationInputEvent, content: CGRect, clip: CGRect, zoom: Double, magnification: Double
    ) -> CGPoint? {
        guard let page = pagePoint(of: event) else { return nil }
        let scale = (event.zoom ?? zoom) * magnification
        let x = content.minX + page.x * scale
        let y = content.minY + page.y * scale
        return CGPoint(x: min(max(x, clip.minX), clip.maxX), y: min(max(y, clip.minY), clip.maxY))
    }
}
