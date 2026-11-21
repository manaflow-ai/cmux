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

    /// What a press at `point` (strip coordinates) is for: the controls the strip's `mouseDown(with:)` acts on,
    /// with a tab narrowed to its drawn pill (a tab's slot ends in the gap before the next pill,
    /// `TabStripMetrics.pillFrame`).
    public func titlebarHit(at point: CGPoint) -> TitlebarHit {
        if isInNewTabButton(point) || isInNewTabMenuButton(point) || arrivingCloseTab(at: point) != nil
            || chipGroup(at: point) != nil { return .strip }
        guard let id = tabID(at: point), let cell = cells[id] else { return .empty }
        let x = convert(point, to: tabsClip).x - cell.frame.minX
        return x < metrics.pillFrame(slotWidth: cell.frame.width, height: cell.frame.height).width ? .strip : .empty
    }

    /// Whether a press at `point` (strip coordinates) is the window's: empty strip space while the strip is the
    /// top row's titlebar. The strip leaves that press alone; the window moves or runs its double-click action.
    func pressIsTitlebar(at point: CGPoint) -> Bool {
        actsAsTitlebar && titlebarHit(at: point) == .empty
    }

    /// Strip-local rects of the controls that take the mouse: every shown tab's pill, the group chips, the + button
    /// and its chooser, each the strip's full height.
    func mouseRects() -> [CGRect] {
        var rects = displayed.compactMap { item -> CGRect? in
            guard let cell = cells[item.id], cell.frame.width > 0.5 else { return nil }
            let pill = metrics.pillFrame(slotWidth: cell.frame.width, height: cell.frame.height)
            let rect = tabsClip.convert(CGRect(x: cell.frame.minX, y: 0, width: pill.width, height: tabsClip.bounds.height), to: self)
            return CGRect(x: rect.minX, y: 0, width: rect.width, height: bounds.height)
        }
        rects += groups.chips.values.map { chip in
            let rect = tabsClip.convert(chip.frame, to: self)
            return CGRect(x: rect.minX, y: 0, width: rect.width, height: bounds.height)
        }
        rects += [newTabButton as NSView, newTabMenuButton].filter { !$0.isHidden }.map { contentView.convert($0.frame, to: self) }
        return rects
    }
}
