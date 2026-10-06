import AppKit
import CmuxNextDesign
import CmuxNextWakeups
import QuartzCore
/// Scrollable document view that renders the sidebar tree.
///
/// Why a custom layer-backed list instead of NSOutlineView: the drag we want
/// (lifted live row, springs on every sibling, a gap that opens in the target
/// container, group-header highlight, a pill that glides between rows) needs
/// per-row frame animation in one CA transaction. NSOutlineView's drag gap is
/// a fixed feedback style, its row animations are insert/remove only, and its
/// drag image is a static snapshot. Here layout is a pure function
/// (`SidebarLayout`), so every change is "compute new frames, animate to them",
/// and only rows near the viewport get views (see `realizationRect`).
final class SidebarListView: NSView {
    let model: SidebarModel
    var displayed = SidebarLayout.empty
    var rowViews: [SidebarRowKey: SidebarRowView] = [:]
    var workspaces: [WorkspaceID: SidebarWorkspace] = [:]
    var tabs: [TabID: SidebarTab] = [:]
    var groups: [GroupID: SidebarGroup] = [:]
    var sections: [SectionID: SidebarSection] = [:]
    /// Pill and gap CALayers, under the rows.
    let decorations = SidebarDecorationView()
    /// Recycled row views by class; only rows near the viewport have views.
    var rowPool = SidebarRowViewPool()
    var hoveredKey: SidebarRowKey?
    /// Workspace hover card (title, cwd, CPU and memory).
    let hoverCard = WorkspaceHoverCardController()
    var press: Press?
    var drag: Drag?
    /// Rows kept invisible while a lifted view stands in for them.
    var suppressed: Set<SidebarRowKey> = []
    /// Inline rename of a workspace or group row.
    let inlineRename = SidebarInlineRename()
    /// Drag autoscroll frames from the window's FrameScheduler.
    lazy var autoscroll = SidebarDragAutoscroll(list: self)
    var external: ExternalDrag?
    /// The active row the last reload laid out (close-focus.md: reveal on change).
    var revealedActive: SidebarRowKey?
    /// The anchor step moves the offset; rows wait for the new layout.
    var isShiftingViewport = false
    /// Offered a row drag whose pointer left the sidebar sideways (another
    /// window, outside every window); true takes it over.
    var onDragHandoff: ((SidebarDragHandoff) -> Bool)?
    /// Hover time before an external tab drag over a row selects it.
    var springLoadDelay: Duration = .milliseconds(500)
    /// Clock for the spring-load delay; tests inject a manual clock.
    var springLoadClock: any Clock<Duration> = ContinuousClock()
    /// A title click's collapse toggle waiting out the double-click interval.
    var pendingGroupToggle: PendingGroupToggle?
    /// How long a group title click waits for a second click.
    var groupToggleDelay: Duration = .milliseconds(Int(NSEvent.doubleClickInterval * 1000))
    /// Clock for the group toggle delay; tests inject a manual clock.
    var clickClock: any Clock<Duration> = ContinuousClock()
    /// Builds the right-click menu for a target (filled by the App from the
    /// action registry). Nil means no context menu.
    var contextMenuProvider: ((SidebarContextTarget) -> NSMenu?)?
    init(model: SidebarModel) {
        self.model = model
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        decorations.autoresizingMask = [.width, .height]
        addSubview(decorations)
        setAccessibilityRole(.outline)
        setAccessibilityLabel(Strings.sidebarLabel)
        hoverCard.list = self
        inlineRename.list = self
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
    isolated deinit {
        // The frame client deactivates in its own deinit (touching the lazy
        // property here would create one that weakly captures a dying self).
        pendingGroupToggle?.task.cancel()
        NotificationCenter.default.removeObserver(self)
    }
    // MARK: - Window occlusion
    private var observedWindow: NSWindow?
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // A move to another window (or none) ends this list's card only.
        hoverCards.unregister(hoverCard)
        if window != nil { hoverCards.register(hoverCard) }
        guard observedWindow !== window else { return }
        let center = NotificationCenter.default
        if let observedWindow { center.removeObserver(self, name: NSWindow.didChangeOcclusionStateNotification, object: observedWindow) }
        observedWindow = window
        if let window {
            center.addObserver(self, selector: #selector(windowOcclusionChanged), name: NSWindow.didChangeOcclusionStateNotification, object: window)
        }
    }
    @objc private func windowOcclusionChanged(_ note: Notification) {
        setWindowVisible(window?.occlusionState.contains(.visible) ?? false)
    }
    /// Pauses (or resumes) every row's activity animation.
    func setWindowVisible(_ visible: Bool) {
        for row in subviews {
            for case let indicator as StatusIndicatorView in row.subviews { indicator.isWindowVisible = visible }
        }
    }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    var metrics: SidebarLayoutMetrics { .standard }
    var inset: CGFloat { SidebarStyle.horizontalInset }
    // MARK: - Reload
    /// Recomputes layout from the model and animates rows to their frames.
    func reload(animated: Bool) {
        workspaces = [:]
        tabs = [:]
        groups = [:]
        sections = [:]
        for section in model.sections {
            sections[section.id] = section
            for node in section.nodes {
                switch node {
                case let .workspace(ws): workspaces[ws.id] = ws
                case let .group(group):
                    groups[group.id] = group
                    for ws in group.workspaces { workspaces[ws.id] = ws }
                }
            }
        }
        for workspace in workspaces.values { for tab in workspace.tabs { tabs[tab.id] = tab } }
        if let drag, !drag.isValid(in: model) { cancelDrag() }
        // A removed workspace's card ends on the geometry check after the
        // rows apply (its anchor is gone); a kept one updates in place.
        if let shown = hoverCard.shownID { hoverCards.contentChanged(WorkspaceHoverCardController.targetID(shown)) }
        applyKeepingViewport(displayLayout(), animated: animated)
    }
    func options(includeGap: Bool) -> SidebarLayoutOptions {
        var o = SidebarLayoutOptions()
        o.filterMatches = model.filterMatches
        o.showWorkspaceTabs = model.showWorkspaceTabs
        o.showsSoleMachineHeader = true
        if includeGap, case let .newWorkspace(section, group, index)? = external?.proposal {
            o.gap = DropPosition(section: section, group: group, index: index)
            o.gapHeight = metrics.rowHeight
        }
        guard let drag else { return o }
        switch drag.payload {
        case let .workspaces(ids):
            o.excludedWorkspaces = Set(ids)
            o.showEmptyPinned = true
        case let .group(group):
            o.excludedGroup = group
        }
        if includeGap, case let .position(position) = drag.target {
            o.gap = position
            o.gapHeight = drag.gapHeight
        }
        return o
    }
    func frame(for row: SidebarRow) -> NSRect {
        NSRect(x: inset, y: row.y, width: max(0, bounds.width - inset * 2), height: row.height)
    }
    /// Rows get views only inside the viewport plus overscan, so 1,000
    /// workspaces cost the same per frame as 40.
    func realizationRect() -> NSRect {
        let visible = enclosingScrollView?.contentView.bounds ?? bounds
        return visible.insetBy(dx: 0, dy: -SidebarStyle.overscan)
    }
    func apply(_ layout: SidebarLayout, animated: Bool) {
        // Rows moved, appeared or left under a possibly still pointer.
        defer { updateHover() }
        let old = displayed
        displayed = layout
        updateDocumentHeight()
        let realize = realizationRect()
        var targets: [(SidebarRowView, NSRect)] = []
        var appearing: [(SidebarRowView, NSRect)] = []
        var keep = Set<SidebarRowKey>()
        let animate = animated && !old.rows.isEmpty
        for row in layout.rows {
            let target = frame(for: row)
            let existing = rowViews[row.key]
            guard existing != nil || target.intersects(realize) else { continue }
            keep.insert(row.key)
            let view = existing ?? dequeue(row.key)
            view.targetSize = target.size
            configure(view, row: row, animated: animate)
            if existing == nil {
                if animate, let previous = old.row(for: row.key) {
                    view.frame = frame(for: previous)
                } else if animate {
                    view.frame = target.offsetBy(dx: 0, dy: -Metrics.space3)
                    view.alphaValue = 0
                } else {
                    view.frame = target
                }
                addSubview(view, positioned: .above, relativeTo: decorations)
                rowViews[row.key] = view
            }
            if suppressed.contains(row.key) {
                view.frame = target
                view.alphaValue = 0
            } else if animate, existing == nil, old.row(for: row.key) == nil {
                appearing.append((view, target))
            } else {
                targets.append((view, target))
            }
        }
        // An empty section's placeholder and the section's rows hand off at
        // once, both ways, so neither fades out under the other.
        let returning = Set(layout.rows.compactMap { row -> SectionID? in
            guard case let .emptySection(section) = row.key, old.row(for: row.key) == nil else { return nil }
            return section
        })
        var leaving: [SidebarRowView] = []
        var replacedRows = false
        for (key, view) in rowViews where !keep.contains(key) {
            rowViews[key] = nil
            let placeholder = if case .emptySection = key { true } else { false }
            let replaced = old.row(for: key).map { returning.contains($0.section) } ?? false
            replacedRows = replacedRows || replaced
            if suppressed.contains(key) || !animate || placeholder || replaced {
                recycle(view)
            } else {
                leaving.append(view)
            }
        }
        let pillFrame = activePillFrame(in: layout)
        // Only an external drop's new-workspace slot has an underlay (R77: a row drag reorders in place).
        let gapFrame = layout.gapHeight > 0 ? layout.gapY.map { NSRect(x: inset, y: $0, width: max(0, bounds.width - inset * 2), height: layout.gapHeight) } : nil
        decorations.frame = bounds
        // A pill whose row the placeholder replaced at once leaves with it.
        decorations.setPill(pillFrame, animated: animate && !(pillFrame == nil && replacedRows))
        decorations.setGap(gapFrame, animated: animate)
        let moves = {
            for (view, target) in targets {
                view.animator().frame = target
                view.animator().alphaValue = 1
            }
        }
        guard animate else {
            Motion.withoutAnimation(moves)
            leaving.forEach(recycle)
            return
        }
        // Existing rows move, new rows (group expand, insert) appear, and
        // removed rows (group collapse, close) leave faster still.
        Motion.animate(.move, in: self, moves)
        Motion.animate(.appear, in: self) {
            for (view, target) in appearing {
                view.animator().frame = target
                view.animator().alphaValue = 1
            }
        }
        Motion.animate(.disappear, in: self, {
            for view in leaving {
                view.animator().alphaValue = 0
                view.animator().frame = view.frame.offsetBy(dx: 0, dy: -Metrics.space3)
            }
        }, completion: { [weak self] in
            guard let self else { return }
            for view in leaving where !self.rowViews.values.contains(where: { $0 === view }) { self.recycle(view) }
            self.pruneOffscreen()
        })
    }
    func activePillFrame(in layout: SidebarLayout) -> NSRect? {
        guard let active = model.activeWorkspaceID,
              !suppressed.contains(.workspace(active)),
              let row = layout.row(for: .workspace(active)) else { return nil }
        return frame(for: row)
    }
    func configure(_ view: SidebarRowView, row: SidebarRow, animated: Bool) {
        view.isHovered = hoveredKey == row.key && drag == nil
        switch (row.key, view) {
        case let (.workspace(id), view as WorkspaceRowView):
            guard let ws = workspaces[id] else { return }
            view.configure(ws, row: row)
            view.isSecondarySelected = model.selection.contains(id) && model.activeWorkspaceID != id
            view.isDropTarget = external?.proposal == .intoWorkspace(id) || drag?.target == .ontoWorkspace(id)
        case let (.tab(_, tabID), view as SidebarTabRowView):
            guard let tab = tabs[tabID] else { return }
            view.configure(tab, row: row)
        case let (.group(id), view as GroupHeaderRowView):
            guard let group = groups[id] else { return }
            view.configure(group, row: row, animated: animated)
            view.isDropTarget = drag?.target == .intoGroup(id) || external?.proposal == .intoGroup(id)
        case let (.section(id), view as SectionHeaderRowView):
            guard let section = sections[id] else { return }
            view.configure(section, row: row)
        case let (.emptySection(id), view as EmptySectionRowView):
            view.configure(pinned: id == .pinned)
        default:
            break
        }
    }
    func updateDocumentHeight() {
        let clipHeight = enclosingScrollView?.contentView.bounds.height ?? 0
        let height = max(displayed.totalHeight, clipHeight)
        if frame.height != height { setFrameSize(NSSize(width: frame.width, height: height)) }
    }
    /// Exactly as wide as the visible clip, and as tall as the rows or the
    /// clip, whichever is taller, on every clip resize too (nxdog56: a clip
    /// that shrank after the rows were laid out kept the old height, so an
    /// empty list showed a scroll bar and scrolled).
    func fitToClip() {
        guard let clip = enclosingScrollView?.contentView else { return }
        if frame.width != clip.bounds.width { setFrameSize(NSSize(width: clip.bounds.width, height: frame.height)) }
        updateDocumentHeight()
    }
    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = newSize.width != frame.width
        super.setFrameSize(newSize)
        guard widthChanged else { return }
        for row in displayed.rows {
            guard let view = rowViews[row.key] else { continue }
            let target = frame(for: row)
            view.targetSize = target.size
            view.frame = target
        }
        decorations.frame = bounds
        decorations.setPill(activePillFrame(in: displayed), animated: false)
    }
    /// Adds views for rows scrolled into range and drops far-away ones.
    func realizeVisibleRows() {
        guard !isShiftingViewport else { return }
        let realize = realizationRect()
        for row in displayed.rows where rowViews[row.key] == nil {
            let target = frame(for: row)
            guard target.intersects(realize) else { continue }
            let view = dequeue(row.key)
            view.targetSize = target.size
            configure(view, row: row, animated: false)
            view.frame = target
            view.alphaValue = suppressed.contains(row.key) ? 0 : 1
            addSubview(view, positioned: .above, relativeTo: decorations)
            rowViews[row.key] = view
        }
        pruneOffscreen()
        updateHover()
    }
    func pruneOffscreen() {
        let keepRect = realizationRect().insetBy(dx: 0, dy: -SidebarStyle.overscan)
        for row in displayed.rows {
            guard let view = rowViews[row.key], !frame(for: row).intersects(keepRect),
                  inlineRename.session?.key != row.key else { continue }
            recycle(view)
            rowViews[row.key] = nil
        }
    }
    /// The selectable rows in visual order (placeholders left out).
    var visibleWorkspaceOrder: [WorkspaceID] {
        let placeholders = Set(model.allWorkspaces.filter { $0.rowState == .placeholder }.map(\.id))
        return displayed.rows.compactMap { if case let .workspace(id) = $0.key, !placeholders.contains(id) { id } else { nil } }
    }
    // MARK: - Hover
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        ))
    }
    override func mouseMoved(with event: NSEvent) { updateHover(event.locationInWindow) }
    override func mouseEntered(with event: NSEvent) { updateHover(event.locationInWindow) }
    override func mouseExited(with event: NSEvent) {
        setHovered(nil)
        hoverCards.pointerMoved(to: window.map { $0.convertPoint(toScreen: event.locationInWindow) })
    }
    /// Hover after a pointer event (`windowPoint`), or after rows moved or
    /// scrolled under a possibly still pointer (no point: the coordinator's
    /// pointer location, and the card re-hit-tests as a geometry change).
    func updateHover(_ windowPoint: NSPoint? = nil) {
        defer {
            if let windowPoint, let window {
                hoverCards.pointerMoved(to: window.convertPoint(toScreen: windowPoint))
            } else {
                hoverCards.geometryChanged(in: window)
            }
        }
        guard drag == nil, let window else { return setHovered(nil) }
        let point = convert(windowPoint ?? window.convertPoint(fromScreen: hoverCards.currentPointer()), from: nil)
        guard visibleRect.contains(point) else { return setHovered(nil) }
        setHovered(displayed.row(at: point.y)?.key)
    }
    func setHovered(_ key: SidebarRowKey?) {
        guard key != hoveredKey else { return }
        if let hoveredKey { rowViews[hoveredKey]?.isHovered = false }
        hoveredKey = key
        if let key { rowViews[key]?.isHovered = true }
    }
}
