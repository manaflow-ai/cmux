public import AppKit
public import CmuxNextDesign

// Dogfood nxdog12/nxdog14: "tabs at top drag full window around". The strip
// answers the window's one titlebar decision (`TitlebarDragPolicy`): only
// empty strip space in the top row moves the window; a tab's pill, a chip and
// + never do. The gaps between them are empty space (#48653).
extension TabStripView: TitlebarPressDeciding {
    public func titlebarPress(atWindowPoint windowPoint: CGPoint) -> TitlebarPress {
        pressIsTitlebar(at: convert(windowPoint, from: nil)) ? .movesWindow : .staysPut
    }

    /// What a press at a strip point is for.
    public enum TitlebarHit: Equatable, Sendable {
        /// A tab's pill, a group chip, the + button or its chooser: the strip handles it and the window stays.
        case strip
        /// Any other strip space, the gaps between pills and buttons too: in the top row it moves the window and a
        /// double-click runs the titlebar action (https://github.com/manaflow-ai/cmux/issues/48653).
        case empty
    }

    /// What a press at `point` (strip coordinates) is for: the controls the strip's `mouseDown(with:)` acts on. While
    /// the strip is the top row's titlebar (`actsAsTitlebar`) a tab or chip is narrowed to its drawn pill (its slot
    /// ends in the gap before the next pill, `TabStripMetrics.pillFrame`), its close and audio buttons' slack kept;
    /// elsewhere the whole slot stays the tab's, so a lower strip's press and drag act as before.
    public func titlebarHit(at point: CGPoint) -> TitlebarHit {
        if isInNewTabButton(point) || isInNewTabMenuButton(point) || arrivingCloseTab(at: point) != nil { return .strip }
        let x = convert(point, to: tabsClip).x
        if let group = chipGroup(at: point) {
            guard actsAsTitlebar, let chip = groups.chips[group] else { return .strip }
            let pill = chip.pillFrame
            return x >= chip.frame.minX + pill.minX && x < chip.frame.minX + pill.maxX ? .strip : .empty
        }
        guard let id = tabID(at: point), let cell = cells[id] else { return .empty }
        guard actsAsTitlebar, !isInCloseButton(id, point), !isInAudioButton(id, point) else { return .strip }
        return x - cell.frame.minX < metrics.pillFrame(slotWidth: cell.frame.width, height: cell.frame.height).width ? .strip : .empty
    }

    /// Whether a press at `point` (strip coordinates) is the window's: empty strip space while the strip is the
    /// top row's titlebar. The strip leaves that press alone; the window moves or runs its double-click action.
    func pressIsTitlebar(at point: CGPoint) -> Bool {
        actsAsTitlebar && titlebarHit(at: point) == .empty
    }

    /// Strip-local rects of the controls that take the mouse, read from ``titlebarHit(at:)`` along the strip's middle
    /// line (one point apart), each the strip's full height: one source for both.
    func mouseRects() -> [CGRect] {
        var rects: [CGRect] = []
        var start: CGFloat?
        let y = bounds.midY
        for x in stride(from: bounds.minX, through: bounds.maxX, by: 1) {
            let control = x < bounds.maxX && titlebarHit(at: CGPoint(x: x, y: y)) == .strip
            if control, start == nil { start = x }
            if !control, let begin = start {
                rects.append(CGRect(x: begin, y: 0, width: x - begin, height: bounds.height))
                start = nil
            }
        }
        return rects
    }
}
