public import AppKit

/// A pane's hosted view that draws its own tools at the trailing end of the pane's tab row
/// (`ChromeTunables.tabRowTools`; Leo 2026-10-14, "why is there even a top bar"): a chat's header
/// tools. While it reports a width, the pane lays the view over the strip's row too and narrows the
/// strip by that width; the strip and the pane's own toolbar stay above the view, so the view
/// draws its tools in the space the strip gave up.
@MainActor
public protocol PaneTabRowSharing: AnyObject {
    /// Points the view's tools take at the row's trailing end, left of the pane's own toolbar;
    /// nil or 0 while it does not share the row.
    var tabRowToolsWidth: CGFloat? { get }
    /// Points the view's tools took the last time they were in the row, kept after the row ends;
    /// nil before they first were. Decides whether a pane offers the row (``fitsTabRow(room:)``).
    var tabRowToolsNeed: CGFloat? { get }
    /// Called whenever ``tabRowToolsWidth`` changes.
    var onTabRowToolsChange: (() -> Void)? { get set }
    /// The row the view may draw its tools in: the top `height` points (0: it does not share the
    /// row now), less `trailingInset` points at the trailing end, where the pane's own toolbar is.
    func setTabRow(height: CGFloat, trailingInset: CGFloat)
}

extension PaneTabRowSharing {
    /// Points the strip gives up beside the view's tools in a row `room` wide (at most half of it).
    public func tabRowWidth(room: CGFloat) -> CGFloat { min(max(0, tabRowToolsWidth ?? 0), max(0, room / 2)) }

    /// Whether the view's tools fit in the half of a row `room` wide that the strip gives up; tools
    /// that do not keep the view's own header row, so in a narrow pane the last tab does not cover
    /// the leading tools. Tools that never reported are offered the row once, to learn their width.
    public func fitsTabRow(room: CGFloat) -> Bool { (tabRowToolsNeed ?? 0) <= max(0, room / 2) }

    /// Offers the view the row (`height` 0: none); a change in its tools' width lays `pane` out
    /// again while the view is still in it (a view another pane took gets its row from that pane).
    public func offerTabRow(height: CGFloat, trailingInset: CGFloat, in pane: NSView) {
        onTabRowToolsChange = { [weak self, weak pane] in
            guard let pane, let view = self as? NSView, view.isDescendant(of: pane) else { return }
            pane.needsLayout = true
        }
        setTabRow(height: height, trailingInset: height > 0 ? trailingInset : 0)
    }
}

/// A pane's hosted view that shares the tab row through the view it wraps (a page tab's view over
/// its page, the docked Home's Chief tools): every requirement goes to ``tabRowSharer``, and with none
/// the view has no tools in the row.
@MainActor
public protocol PaneTabRowForwarding: PaneTabRowSharing {
    var tabRowSharer: PaneTabRowSharing? { get }
}

extension PaneTabRowForwarding {
    public var tabRowToolsWidth: CGFloat? { tabRowSharer?.tabRowToolsWidth }
    public var tabRowToolsNeed: CGFloat? { tabRowSharer?.tabRowToolsNeed }
    public var onTabRowToolsChange: (() -> Void)? {
        get { tabRowSharer?.onTabRowToolsChange }
        set { tabRowSharer?.onTabRowToolsChange = newValue }
    }
    public func setTabRow(height: CGFloat, trailingInset: CGFloat) { tabRowSharer?.setTabRow(height: height, trailingInset: trailingInset) }
}

extension NSView {
    /// The top of a view that shares its pane's tab row (``PaneTabRowSharing``) that the row covers:
    /// 0 points tall while it does not share the row. The pane lays the view under the strip then,
    /// so a native notice pins below this guide, not to the view's top, to stay clear of the tabs.
    public var tabRowCover: NSLayoutGuide {
        if let guide = layoutGuides.first(where: { $0.identifier == Self.tabRowCoverID }) { return guide }
        let guide = NSLayoutGuide()
        guide.identifier = Self.tabRowCoverID
        addLayoutGuide(guide)
        let height = guide.heightAnchor.constraint(equalToConstant: 0)
        height.identifier = Self.tabRowCoverID.rawValue
        NSLayoutConstraint.activate([
            guide.topAnchor.constraint(equalTo: topAnchor),
            guide.leadingAnchor.constraint(equalTo: leadingAnchor),
            guide.trailingAnchor.constraint(equalTo: trailingAnchor),
            height,
        ])
        return guide
    }

    /// Sets ``tabRowCover``'s height: the row's height in points while the view's tools are in it, else 0.
    public func setTabRowCover(_ points: CGFloat) {
        let guide = tabRowCover
        let height = constraints.first { $0.identifier == Self.tabRowCoverID.rawValue && $0.firstItem === guide }
        if height?.constant != max(0, points) { height?.constant = max(0, points) }
    }

    private static let tabRowCoverID = NSUserInterfaceItemIdentifier("cmux.tabRowCover")
}
