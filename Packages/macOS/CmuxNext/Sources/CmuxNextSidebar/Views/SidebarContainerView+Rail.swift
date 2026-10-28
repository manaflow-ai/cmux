public import AppKit
import CmuxNextDesign

// `sidebar.style` = rail (plans/cmux-next/minimal-sidebar.md): while closed the container is the
// rail's few points wide and shows `railView`; resting the pointer on it opens the full sidebar at
// the user's width over the content (the window pins the content beside the rail, not beside this
// view: `WindowRootView+SidebarRail`), on the same width motion as show and hide, so Reduce Motion
// and the animation switches apply. It closes shortly after the pointer leaves.
extension SidebarContainerView {
    /// The panel is out of sight: the sidebar is hidden, or the rail is closed.
    var isPanelCollapsed: Bool { model.isHidden || (model.style == .rail && !model.isRailOpen) }

    /// The rail shows: the rail style, the sidebar shown and its full sidebar closed.
    public var isRailShown: Bool { model.style == .rail && !model.isHidden && !model.isRailOpen }

    /// The open sidebar covers the content, so it needs a surface of its own (the standard
    /// sidebar is clear over the window's backdrop).
    var railOverlayFill: NSColor? {
        model.style == .rail && (!isPanelCollapsed || isWidthAnimating) ? Palette.surfaceBackground : nil
    }

    /// Opens the rail's full sidebar now (a rename, a reveal), over the content. Toggle Sidebar
    /// closes it again. Lays out in this turn so a caller can reach its rows.
    public func revealRail() {
        guard model.style == .rail, !model.isHidden else { return }
        model.isRailOpen = true
        syncRail()
        apply()
    }

    /// Adds the rail over the panel and its hover cards (init).
    func mountRail() {
        railView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(railView)
        NSLayoutConstraint.activate([
            railView.leadingAnchor.constraint(equalTo: leadingAnchor), railView.trailingAnchor.constraint(equalTo: trailingAnchor),
            railView.topAnchor.constraint(equalTo: topAnchor), railView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        railView.bind(model)
        railView.cards = railCards
        railCards.rail = railView
        railCards.coordinator = { [weak self] in self?.sidebarView.hoverCards }
        railCards.digit = { [weak self] id in
            self?.model.itemOrder.number(for: .workspace(id), DesignSettings.shared.sidebarSections.navigation)
        }
        syncRail()
    }

    /// The rail's views follow the model: shown only while the rail is; leaving the style or
    /// hiding the sidebar closes the full sidebar.
    func syncRail() {
        let rail = model.style == .rail && !model.isHidden
        if !rail, model.isRailOpen { model.isRailOpen = false }
        railView.hugsTrailingEdge = side == .right
        railView.isHidden = !isRailShown
        applySurfaceFill()
    }
}
