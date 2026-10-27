public import CoreGraphics

/// Which app window a drag point is over (pure, so the rule is tested
/// without windows). Only cmux content windows take drops. Every other
/// window at the point is looked through: Chromium page child windows (the
/// CEF fork orders them above the content), the overlay plane panel, the
/// drag ghost and app panels. So a drag over a web page resolves against
/// the window that hosts the page (tab-dnd, 2026-10-04).
public nonisolated struct TabDragWindowPick {
    public nonisolated init() {}
    public struct Candidate: Hashable, Sendable {
        public var frame: CGRect
        /// The content window's id; nil for any other window.
        public var controllerID: String?
        public var isVisible: Bool
        /// Whether the window hides an overlay of a content window behind it (``isFrontmost(_:over:in:)``).
        /// False for windows the overlay draws above (the window's own children: its pages, its
        /// overlay panel) and for the drag ghost itself.
        public var occludes: Bool

        public init(frame: CGRect, controllerID: String?, isVisible: Bool = true, occludes: Bool = true) {
            self.frame = frame
            self.controllerID = controllerID
            self.isVisible = isVisible
            self.occludes = occludes
        }
    }

    /// The frontmost content window containing `point`; `ordered` is
    /// front to back. Nil outside every content window.
    public static func frontmost(at point: CGPoint, in ordered: [Candidate]) -> String? {
        ordered.first { $0.isVisible && $0.controllerID != nil && $0.frame.contains(point) }?.controllerID
    }

    /// Whether content window `id` shows all of `rect` in front of every other window: it holds the
    /// rect and no visible window before it in `ordered` (front to back) that ``Candidate/occludes``
    /// meets it. The drag ghost draws in that window's overlay only then: the overlay is a child of
    /// the window, at its level, so a window in front would cover the ghost.
    public static func isFrontmost(_ id: String, over rect: CGRect, in ordered: [Candidate]) -> Bool {
        for candidate in ordered where candidate.isVisible {
            if candidate.controllerID == id { return candidate.frame.contains(rect) }
            if candidate.occludes, candidate.frame.intersects(rect) { return false }
        }
        return false
    }
}
