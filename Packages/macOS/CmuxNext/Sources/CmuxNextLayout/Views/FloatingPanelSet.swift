import AppKit
import CmuxNextDesign
import CmuxNextWakeups

/// The panels of one layout root's floating panes: it makes the windows agree with a ``FloatingPanelPlan``.
///
/// A panel that the plan stops showing goes off the display at once. A panel that the plan starts to show comes
/// at once, or, when the same change shows the root's content in the window, after that change's frame: so the
/// window never shows a panel over the content of another workspace, and such a panel can come one frame late.
/// A change that a layout pass finds waits for the end of that pass's frame: no window changes inside a layout.
final class FloatingPanelSet: NSObject, NSWindowDelegate {
    /// The plan that the windows follow now.
    private(set) var plan = FloatingPanelPlan(contents: [], displays: [], scale: 1)
    /// The plan of the last read (``follow(_:inLayout:)``): the windows follow it now, or after a frame.
    private(set) var wanted = FloatingPanelPlan(contents: [], displays: [], scale: 1)
    /// The pane area of ``wanted``, in the coordinates of the displays.
    private(set) var area = CGRect.zero
    /// One panel for each floating pane that showed: the ones that show, and the ones that wait off the display.
    private(set) var panels: [PaneID: PanePanel] = [:]
    /// The panels made so far (a pane's panel is made once).
    private(set) var made = 0
    /// Runs work after the frame of the change in progress. Tests give their own.
    var afterFrame: (@escaping @MainActor () -> Void) -> Void = { AfterFrameCommit().run($0) }

    private weak var root: LayoutRootView?
    private weak var parent: NSWindow?
    /// Work waits for the end of a frame (``afterFrame``).
    private var waits = false

    /// Reads the floating panes that `root` shows now and makes the panels agree. `inLayout`: the call comes from a
    /// layout pass. Returns the panes whose panel shows: their content is visible.
    func follow(_ root: LayoutRootView, inLayout: Bool = false) -> Set<PaneID> {
        self.root = root
        let context = root.context
        let active = context.model.layoutPassReads.activeScreen, list = active?.floating ?? []
        let window = root.isLive ? root.window : nil
        let view = active.flatMap { root.screenViews[$0.id] }.flatMap { $0.bounds.width > 0 && $0.bounds.height > 0 ? $0 : nil }
        var content = FloatingPanelPlan.Content(workspace: "content", isShown: window != nil && view != nil, isCovered: false,
                                                floating: list, hidden: [],
                                                // A pane that is on another screen, or tiled again, keeps its panel.
                                                elsewhere: Set(panels.keys).intersection(context.livePanes).subtracting(list.map(\.pane)),
                                                area: .zero)
        // No floating pane and no panel (each pass of a layout with none): no read of a window or a display.
        guard !list.isEmpty || !panels.isEmpty else {
            let none = FloatingPanelPlan(contents: [content], displays: [], scale: 1)
            if none != wanted {
                wanted = none
                plan = none
            }
            return []
        }
        if let window, let view { content.area = window.convertToScreen(view.convert(view.bounds, to: nil)) }
        let next = FloatingPanelPlan(contents: [content], displays: NSScreen.screens.map(\.visibleFrame), scale: window?.backingScaleFactor ?? 1)
        let shown = Set(next.panels.map(\.pane))
        if let window { parent = window }
        guard next != wanted else { return shown }
        wanted = next
        area = content.area
        if inLayout { later() } else { apply() }
        return shown
    }

    /// The frames of the panels on the display, in the coordinates of `view`: what they cover of it.
    func covers(in view: NSView) -> [CGRect] {
        guard !panels.isEmpty, let window = view.window else { return [] }
        return panels.values.filter { $0.parent === window }.map { view.convert(window.convertFromScreen($0.frame), from: nil) }
    }

    private func apply(arrives: Bool = false) {
        let steps = wanted.steps(from: plan)
        plan = wanted
        for step in steps {
            switch step {
            case let .leave(pane): if let panel = panels[pane] { hide(panel) }
            case let .dissolve(pane): dissolve(pane)
            case .commit, .move, .arrive, .order: break
            }
        }
        // The window shows this content from this change on: its panels come after the change's frame.
        if !arrives, steps.contains(where: { $0.kind == .commit }), steps.contains(where: { $0.kind == .arrive }) { return later() }
        if arrives || !waits { settle() }
    }

    private func later() {
        guard !waits else { return }
        waits = true
        afterFrame { [weak self] in
            guard let self else { return }
            self.waits = false
            self.apply(arrives: true)
        }
    }

    /// Puts each panel of the plan on the display, at its frame and in the plan's order.
    private func settle() {
        guard let parent, let context = root?.context, !plan.panels.isEmpty else { return }
        var arrived = false
        for entry in plan.panels {
            let panel = panels[entry.pane] ?? make(entry.pane, frame: entry.frame)
            (panel.contentView as? FloatingPanelContentView)?.take(context.host(for: entry.pane))
            // A frame that a person changes now is theirs until the release.
            if panel.frame != entry.frame, !panel.isMoving, !panel.inLiveResize { panel.setFrame(entry.frame, display: true) }
            if panel.parent !== parent {
                parent.addChildWindow(panel, ordered: .above)
                arrived = true
            }
        }
        order(in: parent)
        root?.setNeedsOverlaySync()
        // The pane that has the focus can be in a panel that came now: the keys go to it.
        if arrived { PanePanel.moveKeys(in: parent, toPane: context.model.layoutPassReads.focusedPane?.rawValue) }
    }

    /// The panels of the plan as the parent's children in the plan's order, back to front. A child window gets its
    /// place by its add, so a wrong order is one remove and one add of each panel.
    private func order(in parent: NSWindow) {
        let wanted = plan.panels.compactMap { panels[$0.pane] }
        let now = (parent.childWindows ?? []).compactMap { $0 as? PanePanel }.filter { child in wanted.contains { $0 === child } }
        guard !now.elementsEqual(wanted, by: { $0 === $1 }) else { return }
        let key = wanted.first { $0.isKeyWindow }
        for panel in wanted {
            parent.removeChildWindow(panel)
            parent.addChildWindow(panel, ordered: .above)
        }
        if let key, !key.isKeyWindow { FocusRoute(.system, "a floating pane's panel keeps the keys through a new order").makeKey(key) }
    }

    private func make(_ pane: PaneID, frame: CGRect) -> PanePanel {
        let panel = PanePanel(pane: pane.rawValue, frame: frame)
        panel.barHeight = FloatingPanelFrame.barHeight
        panel.minSize = NSSize(width: FloatingPanelFrame.reach * 3, height: FloatingPanelFrame.barHeight * 5)
        panel.contentView = FloatingPanelContentView(frame: NSRect(origin: .zero, size: frame.size))
        panel.delegate = self
        panel.onPress = { [weak self] in self?.root?.context.model.focus(pane, source: .pointer) }
        panel.onMoved = { [weak self, weak panel] in
            guard let self, let panel else { return }
            self.release(panel, of: pane)
        }
        panels[pane] = panel
        made += 1
        return panel
    }

    /// Takes `panel` off the display. Its pane can float still: the panel and the views in it stay.
    private func hide(_ panel: PanePanel) {
        guard let parent = panel.parent else { return }
        // The parent takes the keys before the panel goes, so AppKit chooses no window for them.
        if panel.isKeyWindow { FocusRoute(.system, "a floating pane's panel leaves the display").makeKey(parent) }
        parent.removeChildWindow(panel)
        panel.orderOut(nil)
        root?.setNeedsOverlaySync()
    }

    /// The pane is gone: its panel ends, and the pane's content goes back if the panel still holds it.
    private func dissolve(_ pane: PaneID) {
        guard let panel = panels.removeValue(forKey: pane) else { return }
        hide(panel)
        if let context = root?.context, let content = panel.contentView as? FloatingPanelContentView, let host = content.host,
           host.superview === content {
            if context.livePanes.contains(pane) { host.removeFromSuperview() } else { context.release(pane) }
        }
        panel.delegate = nil
        panel.close()
    }

    /// A person let go of `panel` after a move or a size change: its frame goes to the model once, as fractions of
    /// the pane area. The model's answer is the frame that shows.
    private func release(_ panel: PanePanel, of pane: PaneID) {
        guard let root else { return }
        let left = panel.frame
        // The window can be at another place than at the last read: the pane area of now gives the fractions.
        _ = follow(root)
        guard area.width > 0, area.height > 0 else { return }
        root.context.model.setFloatingFrame(pane, frame: FloatingPanelFrame.fractions(of: left, in: area))
        // The model can answer with another frame (its limits): the panel goes to it.
        _ = follow(root)
        if let frame = plan.panels.first(where: { $0.pane == pane })?.frame, panel.frame != frame { panel.setFrame(frame, display: true) }
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        guard let panel = notification.object as? PanePanel, let pane = panels.first(where: { $0.value === panel })?.key else { return }
        release(panel, of: pane)
    }

    /// A panel moved (with its parent, or under a pointer): the rings and the dims under it follow, and the plan of
    /// the window's place of now is the one that the panels follow.
    func windowDidMove(_ notification: Notification) {
        guard let root else { return }
        if let panel = notification.object as? PanePanel, !panel.isMoving, !panel.inLiveResize { _ = follow(root) }
        root.setNeedsOverlaySync()
    }

    func windowDidResize(_ notification: Notification) { root?.setNeedsOverlaySync() }
}

/// The content view of a floating pane's panel: the bar at its top, and the pane's host under it.
final class FloatingPanelContentView: NSView {
    /// The host of the panel's pane, while it is in this view.
    private(set) weak var host: PaneHostView?

    override var isFlipped: Bool { true }

    /// Takes `host` from the view that has it and places it under the bar. The host is the pane's own: nothing of
    /// the pane is made again.
    func take(_ host: PaneHostView) {
        self.host = host
        guard host.superview !== self else { return place() }
        addSubview(host)
        // What its screen gave it for its place there goes: a clip, a spring, a dock's fill.
        host.setStripClip(nil)
        host.areaHitClip = nil
        host.isDocked = false
        host.isOnLayoutSpring = false
        host.restOffset = .zero
        if host.isHidden { host.isHidden = false }
        if host.alphaValue != 1 { host.alphaValue = 1 }
        place()
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        place()
    }

    private func place() {
        guard let host, host.superview === self else { return }
        let bar = FloatingPanelFrame.barHeight
        let frame = NSRect(x: 0, y: bar, width: bounds.width, height: max(0, bounds.height - bar))
        if host.frame != frame { host.frame = frame }
        // The window's own corner clips the pane: the host has no padding and no corner of its own.
        host.applyShape(padding: 0, cornerRadius: 0, wholeCard: true)
        host.noteWindowFrame()
    }
}
