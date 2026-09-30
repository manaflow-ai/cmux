public import AppKit
import CmuxNextDesign

// Dogfood nxdog12: "tabs at top drag full window around". In a strip in the
// window's titlebar band, macOS moved the window from a press on a tab,
// because a plain view never claims the band (`TitlebarDragBlocker`). One
// per-point rule now decides both paths: the window server's drag region
// (blockers over the rects below) and the strip's own mouse-down
// (`WindowTitlebar.handleMouseDown` only on empty space).
extension TabStripView {
    /// What a press at a strip point is for.
    public enum TitlebarHit: Equatable, Sendable {
        /// A tab, a group chip, the gap between two of them, the + button or
        /// a trailing button: the strip handles it and the window stays.
        case strip
        /// Empty strip space: in the top row it moves the window and a
        /// double-click runs the titlebar action.
        case empty
    }

    /// Strip-local rects that take the mouse: the run of tabs and chips from
    /// the first one to the + button, and the trailing buttons.
    func mouseRects() -> [CGRect] {
        var rects: [CGRect] = []
        let clip = contentView.convert(tabsClip.frame, to: self)
        let runEnd = newTabButton.isHidden
            ? clip.minX + min(tabRunTrailing(), clip.width)
            : contentView.convert(newTabButton.frame, to: self).maxX
        if runEnd > clip.minX { rects.append(CGRect(x: clip.minX, y: 0, width: runEnd - clip.minX, height: bounds.height)) }
        if !buttonGroup.isHidden {
            let buttons = contentView.convert(buttonGroup.frame, to: self)
            rects.append(CGRect(x: buttons.minX, y: 0, width: buttons.width, height: bounds.height))
        }
        return rects
    }

    /// The per-point decision (pure): a point outside every mouse rect is
    /// empty strip space.
    public static func titlebarHit(at point: CGPoint, mouseRects: [CGRect]) -> TitlebarHit {
        mouseRects.contains { $0.minX <= point.x && point.x < $0.maxX } ? .strip : .empty
    }

    /// What a press at `point` (strip coordinates) is for.
    public func titlebarHit(at point: CGPoint) -> TitlebarHit {
        Self.titlebarHit(at: point, mouseRects: mouseRects())
    }

    /// Places one blocker per mouse rect below the strip's content. Runs
    /// after every frame change; a blocker whose frame is unchanged is not
    /// touched.
    func updateDragBlockers() {
        let rects = mouseRects()
        while dragBlockers.count < rects.count {
            let blocker = TitlebarDragBlocker(frame: .zero)
            addSubview(blocker, positioned: .below, relativeTo: nil)
            dragBlockers.append(blocker)
        }
        while dragBlockers.count > rects.count { dragBlockers.removeLast().removeFromSuperview() }
        for (blocker, rect) in zip(dragBlockers, rects) where blocker.frame != rect { blocker.frame = rect }
    }

    /// The tabs' trailing edge in the clip, scrolled (for a strip whose +
    /// button is hidden).
    private func tabRunTrailing() -> CGFloat {
        let ends = cells.values.map(\.frame.maxX) + groups.chips.values.map(\.frame.maxX)
        return max(0, ends.max() ?? 0)
    }
}
