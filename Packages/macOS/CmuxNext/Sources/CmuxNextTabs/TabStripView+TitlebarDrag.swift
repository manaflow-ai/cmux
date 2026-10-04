public import AppKit
public import CmuxNextDesign

// Dogfood nxdog12/nxdog14: "tabs at top drag full window around". The strip
// answers the window's one titlebar decision (`TitlebarDragPolicy`): only
// empty strip space in the top row moves the window; a tab, a chip, the gap
// between two, + and the trailing buttons never do.
extension TabStripView: TitlebarPressDeciding {
    public func titlebarPress(atWindowPoint windowPoint: CGPoint) -> TitlebarPress {
        actsAsTitlebar && titlebarHit(at: convert(windowPoint, from: nil)) == .empty ? .movesWindow : .staysPut
    }

    /// What a press at a strip point is for.
    public enum TitlebarHit: Equatable, Sendable {
        /// A tab, a group chip, the gap between two of them, the + button, the
        /// location field or a trailing button: the strip handles it and the window stays.
        case strip
        /// Empty strip space: in the top row it moves the window and a
        /// double-click runs the titlebar action.
        case empty
    }

    /// Strip-local rects that take the mouse: the run of tabs and chips from
    /// the first one to the + button, the location field and the trailing buttons.
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

    /// The tabs' trailing edge in the clip, scrolled (for a strip whose +
    /// button is hidden).
    private func tabRunTrailing() -> CGFloat {
        let ends = cells.values.map(\.frame.maxX) + groups.chips.values.map(\.frame.maxX)
        return max(0, ends.max() ?? 0)
    }
}
