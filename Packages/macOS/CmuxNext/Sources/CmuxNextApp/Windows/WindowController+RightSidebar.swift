import AppKit
import CmuxNextDesign

// The right sidebar (inventory row 24): one shared path for its toggle, focus
// and section actions (palette, menu, keyboard, `cmux action run`, MCP). The
// window root insets the main pane by its width, on the edge opposite the
// sidebar.
extension WindowController {
    /// Shows the right sidebar at `mode` (the remembered section when nil).
    /// Returns false, changing nothing, when `mode` has no section.
    @discardableResult
    func showRightSidebar(_ mode: RightSidebarMode? = nil, focus: Bool = false) -> Bool {
        let sections = services.rightSidebarSections
        let target = mode ?? (sections.modes.contains(rightSidebar.mode) ? rightSidebar.mode : sections.modes.first)
        guard let target, sections.modes.contains(target) else { return false }
        let view = rightSidebarPanel()
        guard view.show(target) else { return false }
        rightSidebar.show(target)
        applyRightSidebar()
        (view.shownSection as? RightSidebarRefreshing)?.refresh()
        if focus, let section = view.shownSection { window?.makeFirstResponder(Self.firstKeyView(in: section) ?? section) }
        return true
    }

    func hideRightSidebar() {
        if let view = rightSidebarView, let responder = window?.firstResponder as? NSView, responder.isDescendant(of: view) {
            // The keyboard goes back to the focused pane's content before the view hides.
            window?.makeFirstResponder(nil)
            if let pane = content?.layoutModel.focusedPane?.rawValue { focus.send(.focusPane(pane, source: .programmatic)) }
        }
        rightSidebar.hide()
        applyRightSidebar()
    }

    func toggleRightSidebar() {
        if rightSidebar.isVisible { hideRightSidebar() } else { showRightSidebar() }
    }

    /// Puts the model's state on screen: the panel's width in the root.
    func applyRightSidebar() {
        root.rightPanelWidth = rightSidebar.isVisible ? rightSidebar.width : 0
    }

    /// A drag on the panel's inner edge: follows the pointer live (no animation, the drag is the
    /// person's own pacing), and remembers the width when it ends (`proposed` nil).
    func resizeRightSidebar(to proposed: CGFloat?) {
        guard let proposed else { return rightSidebar.saveWidth() }
        rightSidebar.resize(to: proposed)
        applyRightSidebar()
    }

    /// The window's panel, made on first use.
    private func rightSidebarPanel() -> RightSidebarView {
        if let rightSidebarView { return rightSidebarView }
        let registry = services.registry
        let sections = services.rightSidebarSections
        let view = RightSidebarView(
            modes: sections.modes,
            title: { registry.descriptor(for: $0.actionID)?.title ?? $0.rawValue },
            icon: sections.icon,
            makeSection: { [weak self] mode in self.flatMap { sections.makeView(mode, for: $0) } },
            run: { registry.perform($0) })
        view.onResize = { [weak self] in self?.resizeRightSidebar(to: $0) }
        rightSidebarView = view
        root.rightPanel = view
        return view
    }

    /// The first text field under `view` (a section's search field: the focus
    /// model reads it as a text field), else the first view that takes the keyboard.
    private static func firstKeyView(in view: NSView) -> NSView? {
        func search(_ view: NSView, _ accepts: (NSView) -> Bool) -> NSView? {
            if accepts(view) { return view }
            for subview in view.subviews where !subview.isHidden { if let found = search(subview, accepts) { return found } }
            return nil
        }
        return search(view) { $0 is NSTextField && $0.acceptsFirstResponder } ?? search(view) { $0.acceptsFirstResponder }
    }
}
