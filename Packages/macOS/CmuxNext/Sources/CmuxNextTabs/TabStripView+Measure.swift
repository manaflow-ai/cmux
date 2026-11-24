public import AppKit
public import CmuxNextDesign

// Pane chrome measurement (`debug.pane_chrome`, tests).
extension TabStripView {
    /// The first (leftmost) tab's pill in this view's coordinates (flipped,
    /// top-left origin), or nil with no tab.
    public var firstTabPillFrame: CGRect? {
        guard let cell = cells.values.filter({ $0.frame.width > 0.5 }).min(by: { $0.frame.minX < $1.frame.minX }) else { return nil }
        let pill = cell.pillFrameInCell
        let origin = tabsClip.convert(CGPoint(x: cell.frame.minX + pill.minX, y: cell.frame.minY + pill.minY), to: self)
        return CGRect(origin: origin, size: pill.size)
    }

    /// Every laid-out tab's [x, width] in strip content points, in order
    /// (members collapsed behind a group chip and the drop gap left out).
    public var tabSlots: [[Double]] {
        result.slots.filter { !$0.isCollapsed && $0.id != Self.placeholderID }.map { [Double($0.x), Double($0.width)] }
    }

    /// The width the tabs may fill.
    public var tabAvailableWidth: Double { Double(result.availableWidth) }

    /// The narrowest strip at which no tab shrinks: its end gaps, the window controls it keeps clear of, the pinned tabs,
    /// chips and every other tab at its full width, and the + controls. A row gives its accessories only what is past
    /// this (``TabRowAccessoryFit``, #53314); infinite for a tab that fills the strip (Full Width Tab).
    public var naturalWidth: CGFloat {
        if case .fullWidth = result.share { return .infinity }
        let padding = metrics.endGap(scale: window?.backingScaleFactor ?? 2)
        let share = TabLayoutEngine.rowShare(count: result.flexibleCount, available: .greatestFiniteMagnitude, style: model.style, metrics: metrics)
        let tabs = (0..<result.flexibleCount).reduce(result.reservedWidth) { $0 + share.width(at: $1) }
        return 2 * padding + windowControlsInset + tabs + (model.showsNewTabButton ? newTabLeadingGap + newTabControlsWidth : 0)
    }

    /// Lays the superview (the pane) out again when the layout just made changed ``naturalWidth`` (a tab opened or
    /// closed, a group collapsed, Full Width Tab): the room a chat's summary gets in the row follows it (#53314). Only
    /// then, never on a title or a badge.
    func noteNaturalWidth() {
        let width = naturalWidth
        guard width != reportedNaturalWidth else { return }
        reportedNaturalWidth = width
        superview?.needsLayout = true
    }
}

// `debug.top_alignment`: the strip and its first pill (the topmost strip is the top row's).
extension TabStripView: TopAlignmentReporting {
    public var topAlignmentKind: String { "strip" }

    public func topAlignmentFrames() -> [String: CGRect] {
        firstTabPillFrame.map { ["pill": $0] } ?? [:]
    }
}
