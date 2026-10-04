import AppKit

/// A window's content view as the agent cursor's coordinate space: flipped
/// (origin top-left, y down) whatever the view's own flip, so viewport CSS
/// px map with `minY + y` like everywhere else in the cursor module.
struct AgentCursorContentSpace {
    let contentView: NSView

    init(_ contentView: NSView) { self.contentView = contentView }

    var bounds: CGRect { CGRect(origin: .zero, size: contentView.bounds.size) }

    /// `rect` (in `view`) in this space.
    func rect(_ rect: CGRect, from view: NSView) -> CGRect {
        flip(contentView.convert(rect, from: view))
    }

    /// `rect` (in this space) in `view`.
    func rect(_ rect: CGRect, to view: NSView) -> CGRect {
        view.convert(flip(rect), from: contentView)
    }

    /// Flipping is its own inverse.
    private func flip(_ rect: CGRect) -> CGRect {
        guard !contentView.isFlipped else { return rect }
        return CGRect(x: rect.minX, y: contentView.bounds.height - rect.maxY, width: rect.width, height: rect.height)
    }
}
