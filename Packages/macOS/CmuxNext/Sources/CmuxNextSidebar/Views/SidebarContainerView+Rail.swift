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

    /// Opens the rail's full sidebar now (a rename, a reveal); it closes like a hover once the
    /// pointer is away. Lays out in this turn so a caller can reach its rows.
    public func revealRail() {
        guard model.style == .rail, !model.isHidden else { return }
        railPeek.send(.reveal)
        syncRail()
        apply()
    }

    /// Adds the rail and the pointer tracker over the panel (init).
    func mountRail() {
        let tracker = railPeek.tracker
        for view in [railView, tracker] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: leadingAnchor), view.trailingAnchor.constraint(equalTo: trailingAnchor),
                view.topAnchor.constraint(equalTo: topAnchor), view.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        }
        railView.bind(model)
        railView.onOpenRequest = { [weak self] in self?.revealRail() }
        railPeek.onChange = { [weak self] open in
            guard let self, self.model.isRailOpen != open else { return }
            self.model.isRailOpen = open
        }
        railPeek.isBusy = { [weak self] in self?.isBusyInSidebar ?? false }
        syncRail()
    }

    /// The rail's views follow the model: shown only while the rail is, the tracker only in the
    /// rail style; leaving the style or hiding the sidebar closes it.
    func syncRail() {
        let rail = model.style == .rail && !model.isHidden
        if !rail, railPeek.state.isOpen || model.isRailOpen {
            railPeek.send(.reset)
            model.isRailOpen = false
        }
        railView.hugsTrailingEdge = side == .right
        railView.isHidden = !isRailShown
        railPeek.tracker.isHidden = !rail
        applySurfaceFill()
    }

    /// A drag (a button down), a menu tracking, or a field being edited in the sidebar: the
    /// person is still working there, so the open sidebar waits.
    private var isBusyInSidebar: Bool {
        if NSEvent.pressedMouseButtons != 0 || RunLoop.current.currentMode == .eventTracking { return true }
        guard let editor = window?.firstResponder as? NSText else { return false }
        return editor.isDescendant(of: sidebarView)
    }
}
