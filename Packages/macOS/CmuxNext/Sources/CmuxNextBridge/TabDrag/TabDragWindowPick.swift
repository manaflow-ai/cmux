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

        public init(frame: CGRect, controllerID: String?, isVisible: Bool = true) {
            self.frame = frame
            self.controllerID = controllerID
            self.isVisible = isVisible
        }
    }

    /// The frontmost content window containing `point`; `ordered` is
    /// front to back. Nil outside every content window.
    public static func frontmost(at point: CGPoint, in ordered: [Candidate]) -> String? {
        ordered.first { $0.isVisible && $0.controllerID != nil && $0.frame.contains(point) }?.controllerID
    }
}
