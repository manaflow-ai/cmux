public import AppKit

extension NSView {
    /// Whether no window draws this view: it has no window, it or an
    /// ancestor is hidden, or its window does not draw.
    ///
    /// An agent moves such a WebKit tab into a render window before it drives
    /// it (`AgentRenderWindows`).
    /// - Parameter windowDraws: Whether a window draws its content; the
    ///   default is ``AppKit/NSWindow/drawsContent``. Tests pass a fixed answer.
    /// - Returns: True when a person cannot see this view now.
    public func isOffScreen(windowDraws: @MainActor (NSWindow) -> Bool = { $0.drawsContent }) -> Bool {
        guard let window, !isHiddenOrHasHiddenAncestor else { return true }
        return !windowDraws(window)
    }
}
