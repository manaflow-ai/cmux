public import CoreGraphics

/// The pure visibility rules for an agent cursor target (a browser tab).
/// No AppKit: the App builds an `AgentCursorVisibilitySnapshot` from the live
/// models and asks here. Shared vectors: schemas/agent-cursor-visibility.
public nonisolated enum AgentCursorVisibilityResolver {
    /// Thickness of an edge anchor (column edge, window edge).
    public static let edgeThickness: CGFloat = 4

    public static func resolve(target: String, in snapshot: AgentCursorVisibilitySnapshot) -> AgentCursorVisibility {
        .notDrawn(.tabClosed) // red: rules land in the next commit
    }

    /// `rect` moved into `bounds` so the overlay plane can draw it: the part
    /// inside when there is one, else a zero-thickness rect on the nearest
    /// edge (a sidebar row sits left of the layout root, so its indicator
    /// draws on the content's leading edge at the row's height).
    public static func drawableRect(_ rect: CGRect, in bounds: CGRect) -> CGRect {
        rect // red
    }
}
