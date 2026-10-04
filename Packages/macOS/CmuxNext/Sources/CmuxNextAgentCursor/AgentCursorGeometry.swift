public import CmuxAgentCursor
public import CoreGraphics

/// Pure mapping from an `automation.input` event to overlay coordinates.
public enum AgentCursorGeometry {
    /// The page point the input lands on: `point`, else the center of
    /// `rect` (type and key may carry only the focused element), else nil.
    public static func pagePoint(of event: AutomationInputEvent) -> CGPoint? {
        _ = event
        return nil
    }

    /// Viewport CSS px times `zoom * magnification`, offset by the content
    /// origin, clamped into the content rect so the cursor never lands on a
    /// neighboring pane.
    public static func overlayPoint(
        of event: AutomationInputEvent, content: CGRect, magnification: Double
    ) -> CGPoint? {
        _ = (event, content, magnification)
        return nil
    }
}
