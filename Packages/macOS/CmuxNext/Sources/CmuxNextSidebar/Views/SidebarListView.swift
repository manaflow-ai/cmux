import AppKit
import CmuxNextDesign
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
final class SidebarListView: NSView, NSTextFieldDelegate, NSMenuItemValidation {
    let model: SidebarModel

    private(set) var displayed = SidebarLayout(rows: [], totalHeight: 0, gapY: nil, gapHeight: 0, gapShift: 0)
    private var rowViews: [SidebarRowKey: SidebarRowView] = [:]
    private var workspaces: [WorkspaceID: SidebarWorkspace] = [:]
    private var groups: [GroupID: SidebarGroup] = [:]
    private var sections: [SectionID: SidebarSection] = [:]
    private let pill = SelectionPillView()
    private let gapView = GapIndicatorView()
    private var compact = false
    private var hoveredKey: SidebarRowKey?
    private var press: Press?
    private var drag: Drag?
    /// Rows kept invisible while a lifted view stands in for them.
    private var suppressed: Set<SidebarRowKey> = []
    private var rename: Rename?
    private var autoscrollLink: CADisplayLink?
    private var external: ExternalDrag?

    /// Hover time before an external tab drag over a row selects it.
    var springLoadDelay: Duration = .milliseconds(500)
    /// Clock for the spring-load delay; tests inject a manual clock.
    var springLoadClock: any Clock<Duration> = ContinuousClock()

    /// Called when the list wants the search field focused (typing while the
    /// list is focused).
    var onTypeToSearch: ((String) -> Void)?

    init(model: SidebarModel) {
        self.model = model
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        addSubview(pill)
        addSubview(gapView)
        pill.alphaValue = 0
        gapView.alphaValue = 0
        setAccessibilityRole(.outline)
        setAccessibilityLabel(Strings.sidebarLabel)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    isolated deinit {
        autoscrollLink?.invalidate()
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    private var metrics: SidebarLayoutMetrics { compact ? .compact : .expanded }
    private var inset: CGFloat { compact ? 6 : SidebarStyle.horizontalInset }

    // MARK: - Reload

    /// Recomputes layout from the model and animates rows to their frames.
    func reload(animated: Bool) {
        compact = model.presentation == .iconsOnly
        workspaces = [:]
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
        if let drag, !drag.isValid(in: model) { cancelDrag() }
        apply(SidebarLayout.make(sections: model.sections, metrics: metrics, options: options(includeGap: true)), animated: animated)
    }

    private func options(includeGap: Bool) -> SidebarLayoutOptions {
        var o = SidebarLayoutOptions()
        o.filterMatches = model.filterMatches
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

    private func frame(for row: SidebarRow) -> NSRect {
        NSRect(x: inset, y: row.y, width: max(0, bounds.width - inset * 2), height: row.height)
    }

    /// Rows get views only inside the viewport plus overscan, so 1,000
    /// workspaces cost the same per frame as 40.
    private func realizationRect() -> NSRect {
        let visible = enclosingScrollView?.contentView.bounds ?? bounds
        return visible.insetBy(dx: 0, dy: -SidebarStyle.overscan)
    }

    private func apply(_ layout: SidebarLayout, animated: Bool) {
        let old = displayed
        displayed = layout
        updateDocumentHeight()
        let realize = realizationRect()
        var targets: [(SidebarRowView, NSRect)] = []
        var keep = Set<SidebarRowKey>()
        let animate = animated && !old.rows.isEmpty

        for row in layout.rows {
            let target = frame(for: row)
            let existing = rowViews[row.key]
            guard existing != nil || target.intersects(realize) else { continue }
            keep.insert(row.key)
            let view = existing ?? dequeue(row.key)
            configure(view, row: row, animated: animate)
            if existing == nil {
                if animate, let previous = old.row(for: row.key) {
                    view.frame = frame(for: previous)
                } else if animate {
                    view.frame = target.offsetBy(dx: 0, dy: -6)
                    view.alphaValue = 0
                } else {
                    view.frame = target
                }
                addSubview(view, positioned: .below, relativeTo: gapView)
                rowViews[row.key] = view
            }
            if suppressed.contains(row.key) {
                view.frame = target
                view.alphaValue = 0
            } else {
                targets.append((view, target))
            }
        }

        var leaving: [SidebarRowView] = []
        for (key, view) in rowViews where !keep.contains(key) {
            rowViews[key] = nil
            if suppressed.contains(key) || !animate {
                view.removeFromSuperview()
            } else {
                leaving.append(view)
            }
        }

        let pillFrame = activePillFrame(in: layout)
        let gapFrame = layout.gapY.map { NSRect(x: inset, y: $0, width: max(0, bounds.width - inset * 2), height: layout.gapHeight) }
        if gapFrame != nil, gapView.alphaValue == 0, let f = gapFrame { gapView.frame = f }

        let changes = {
            for (view, target) in targets {
                view.animator().frame = target
                view.animator().alphaValue = 1
            }
            for view in leaving {
                view.animator().alphaValue = 0
                view.animator().frame = view.frame.offsetBy(dx: 0, dy: -6)
            }
            if let pillFrame {
                if self.pill.alphaValue == 0 { self.pill.frame = pillFrame }
                self.pill.animator().frame = pillFrame
                self.pill.animator().alphaValue = 1
            } else {
                self.pill.animator().alphaValue = 0
            }
            if let gapFrame {
                self.gapView.animator().frame = gapFrame
                self.gapView.animator().alphaValue = 1
            } else {
                self.gapView.animator().alphaValue = 0
            }
        }
        if animate {
            Motion.animate(Motion.layout, changes) { [weak self] in
                for view in leaving where view.alphaValue == 0 { view.removeFromSuperview() }
                self?.pruneOffscreen()
            }
        } else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                context.allowsImplicitAnimation = false
                changes()
            }
            leaving.forEach { $0.removeFromSuperview() }
        }
    }

    private func activePillFrame(in layout: SidebarLayout) -> NSRect? {
        guard let active = model.activeWorkspaceID,
              !suppressed.contains(.workspace(active)),
              let row = layout.row(for: .workspace(active)) else { return nil }
        return frame(for: row)
    }

    private func dequeue(_ key: SidebarRowKey) -> SidebarRowView {
        switch key {
        case let .workspace(id):
            let view = WorkspaceRowView(key: key)
            view.onClose = { [weak self] in self?.model.send(.close([id])) }
            return view
        case .group:
            return GroupHeaderRowView(key: key)
        case let .section(sectionID):
            let view = SectionHeaderRowView(key: key)
            if case let .machine(machine) = sectionID {
                view.onAdd = { [weak self] in self?.model.send(.newWorkspace(machine: machine, group: nil)) }
            } else {
                view.allowsAdd = false
            }
            return view
        case .emptySection:
            return EmptySectionRowView(key: key)
        }
    }

    private func configure(_ view: SidebarRowView, row: SidebarRow, animated: Bool) {
        view.isHovered = hoveredKey == row.key && drag == nil
        switch (row.key, view) {
        case let (.workspace(id), view as WorkspaceRowView):
            guard let ws = workspaces[id] else { return }
            view.configure(ws, row: row, compact: compact)
            view.isSecondarySelected = model.selection.contains(id) && model.activeWorkspaceID != id
            view.isDropTarget = external?.proposal == .intoWorkspace(id)
        case let (.group(id), view as GroupHeaderRowView):
            guard let group = groups[id] else { return }
            view.configure(group, row: row, compact: compact, animated: animated)
            view.isDropTarget = drag?.target == .intoGroup(id) || external?.proposal == .intoGroup(id)
        case let (.section(id), view as SectionHeaderRowView):
            guard let section = sections[id] else { return }
            view.configure(section, row: row, compact: compact)
        case let (.emptySection(id), view as EmptySectionRowView):
            view.configure(pinned: id == .pinned, compact: compact)
        default:
            break
        }
    }

    private func updateDocumentHeight() {
        let clipHeight = enclosingScrollView?.contentView.bounds.height ?? 0
        let height = max(displayed.totalHeight, clipHeight)
        if frame.height != height { setFrameSize(NSSize(width: frame.width, height: height)) }
    }

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = newSize.width != frame.width
        super.setFrameSize(newSize)
        guard widthChanged else { return }
        for row in displayed.rows {
            guard let view = rowViews[row.key] else { continue }
            view.frame = frame(for: row)
        }
        if let pillFrame = activePillFrame(in: displayed) { pill.frame = pillFrame }
    }

    /// Adds views for rows scrolled into range and drops far-away ones.
    func realizeVisibleRows() {
        let realize = realizationRect()
        for row in displayed.rows where rowViews[row.key] == nil {
            let target = frame(for: row)
            guard target.intersects(realize) else { continue }
            let view = dequeue(row.key)
            configure(view, row: row, animated: false)
            view.frame = target
            view.alphaValue = suppressed.contains(row.key) ? 0 : 1
            addSubview(view, positioned: .below, relativeTo: gapView)
            rowViews[row.key] = view
        }
        pruneOffscreen()
        updateHover()
    }

    private func pruneOffscreen() {
        let keepRect = realizationRect().insetBy(dx: 0, dy: -SidebarStyle.overscan)
        for row in displayed.rows {
            guard let view = rowViews[row.key], !frame(for: row).intersects(keepRect),
                  rename?.key != row.key else { continue }
            view.removeFromSuperview()
            rowViews[row.key] = nil
        }
    }

    var visibleWorkspaceOrder: [WorkspaceID] {
        displayed.rows.compactMap { if case let .workspace(id) = $0.key { id } else { nil } }
    }

    /// Scrolls so the active workspace row is fully visible.
    func revealActive() {
        guard let active = model.activeWorkspaceID, let row = displayed.row(for: .workspace(active)) else { return }
        scrollToVisible(frame(for: row).insetBy(dx: 0, dy: -8))
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
    override func mouseExited(with event: NSEvent) { setHovered(nil) }

    private func updateHover(_ windowPoint: NSPoint? = nil) {
        guard drag == nil, let window else { return setHovered(nil) }
        let point = convert(windowPoint ?? window.mouseLocationOutsideOfEventStream, from: nil)
        guard visibleRect.contains(point) else { return setHovered(nil) }
        setHovered(displayed.row(at: point.y)?.key)
    }

    private func setHovered(_ key: SidebarRowKey?) {
        guard key != hoveredKey else { return }
        if let hoveredKey { rowViews[hoveredKey]?.isHovered = false }
        hoveredKey = key
        if let key { rowViews[key]?.isHovered = true }
    }

    // MARK: - Mouse

    private struct Press {
        var key: SidebarRowKey
        var point: NSPoint
        var deferredClick: WorkspaceID?
        var cancelled = false
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        if rename != nil { endRename(commit: true) }
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        guard let row = displayed.row(at: point.y) else {
            press = nil
            return
        }
        var press = Press(key: row.key, point: point)
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        switch row.key {
        case let .workspace(id):
            if event.clickCount == 2, flags.isEmpty {
                self.press = nil
                beginRename(row.key)
                return
            }
            if flags.contains(.command) {
                model.toggleSelection(id)
            } else if flags.contains(.shift) {
                model.extendSelection(to: id, visibleOrder: visibleWorkspaceOrder)
            } else if model.selection.contains(id), model.selection.count > 1 {
                // Keep the multi-selection so it can be dragged; collapse it
                // on mouse-up if no drag happens.
                press.deferredClick = id
            } else {
                model.click(id)
            }
            reload(animated: true)
        case let .group(group):
            if event.clickCount == 2 {
                // The first click toggled; undo that and rename instead.
                model.send(.toggleCollapse(.group(group)))
                self.press = nil
                reload(animated: true)
                beginRename(row.key)
                return
            }
        case .section, .emptySection:
            break
        }
        self.press = press
    }

    override func mouseDragged(with event: NSEvent) {
        guard let press, !press.cancelled else { return }
        if drag == nil {
            let point = convert(event.locationInWindow, from: nil)
            guard hypot(point.x - press.point.x, point.y - press.point.y) >= SidebarStyle.dragThreshold,
                  !model.isFiltering else { return }
            beginDrag(press)
            guard drag != nil else { return }
        }
        updateDrag(windowPoint: event.locationInWindow)
    }

    override func mouseUp(with event: NSEvent) {
        defer { press = nil }
        if drag != nil {
            finishDrag()
            return
        }
        guard let press, !press.cancelled else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard displayed.row(at: point.y)?.key == press.key else { return }
        switch press.key {
        case .workspace:
            if let id = press.deferredClick { model.click(id) }
        case let .group(group):
            model.send(.toggleCollapse(.group(group)))
        case let .section(section):
            model.send(.toggleCollapse(.section(section)))
        case .emptySection:
            break
        }
        reload(animated: true)
    }

    // MARK: - Drag

    private final class Drag {
        let payload: DragPayload
        let grabbedKey: SidebarRowKey
        /// Keys hidden while dragging (the lifted rows).
        let hiddenKeys: Set<SidebarRowKey>
        let grabOffsetY: CGFloat
        let gapHeight: CGFloat
        let lift: DragLiftView
        var target: DropTarget?
        var lastWindowPoint: NSPoint = .zero

        init(payload: DragPayload, grabbedKey: SidebarRowKey, hiddenKeys: Set<SidebarRowKey>, grabOffsetY: CGFloat, gapHeight: CGFloat, lift: DragLiftView, target: DropTarget?) {
            self.payload = payload
            self.grabbedKey = grabbedKey
            self.hiddenKeys = hiddenKeys
            self.grabOffsetY = grabOffsetY
            self.gapHeight = gapHeight
            self.lift = lift
            self.target = target
        }

        @MainActor func isValid(in model: SidebarModel) -> Bool {
            switch payload {
            case let .workspaces(ids): ids.allSatisfy { model.workspace($0) != nil }
            case let .group(group): model.group(group) != nil
            }
        }
    }

    private func beginDrag(_ press: Press) {
        guard let row = displayed.row(for: press.key) else { return }
        let payload: DragPayload
        var hidden: Set<SidebarRowKey>
        let origin: DropTarget?
        switch press.key {
        case let .workspace(id):
            let ids = model.selection.contains(id) ? model.orderedSelection : [id]
            if !model.selection.contains(id) { model.click(id) }
            payload = .workspaces(ids)
            hidden = Set(ids.map(SidebarRowKey.workspace))
            origin = ids.first.flatMap { SidebarEdits.position(of: $0, in: model.sections) }.map(DropTarget.position)
        case let .group(group):
            guard let (s, n) = SidebarEdits.locateGroup(group, in: model.sections) else { return }
            payload = .group(group)
            hidden = [.group(group)]
            for ws in groups[group]?.workspaces ?? [] { hidden.insert(.workspace(ws.id)) }
            origin = .position(DropPosition(section: model.sections[s].id, index: n))
        case .section, .emptySection:
            return
        }

        let rowFrame = frame(for: row)
        let count: Int
        if case let .workspaces(ids) = payload { count = ids.count } else { count = 1 }
        let content = dequeue(press.key)
        configure(content, row: row, animated: false)
        content.isHovered = false
        (content as? WorkspaceRowView)?.isSecondarySelected = false
        let lift = DragLiftView(content: content, count: count)
        lift.frame = rowFrame
        addSubview(lift)

        let drag = Drag(
            payload: payload,
            grabbedKey: press.key,
            hiddenKeys: hidden,
            grabOffsetY: press.point.y - rowFrame.minY,
            gapHeight: row.height,
            lift: lift,
            target: origin
        )
        self.drag = drag
        suppressed.formUnion(hidden)
        setHovered(nil)
        for key in hidden { rowViews[key]?.alphaValue = 0 }
        reload(animated: true)
        lift.setLifted(true, animated: true)
        startAutoscroll()
    }

    private func updateDrag(windowPoint: NSPoint) {
        guard let drag else { return }
        drag.lastWindowPoint = windowPoint
        let point = convert(windowPoint, from: nil)

        // The lifted row follows the pointer vertically; x stays locked.
        var liftFrame = drag.lift.frame
        let visible = visibleRect
        liftFrame.origin.y = min(max(point.y - drag.grabOffsetY, visible.minY - liftFrame.height / 2), visible.maxY - liftFrame.height / 2)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        drag.lift.frame = liftFrame
        CATransaction.commit()

        guard let baseY = DropResolver.baseY(forDisplayY: point.y, gapY: displayed.gapY, gapHeight: displayed.gapShift) else { return }
        let base = SidebarLayout.make(sections: model.sections, metrics: metrics, options: options(includeGap: false))
        let target = DropResolver.resolve(y: baseY, payload: drag.payload, base: base, sections: model.sections)
        guard target != drag.target else { return }
        drag.target = target
        drag.lift.setRefused(target == nil)
        reload(animated: true)
    }

    private func finishDrag() {
        guard let drag else { return }
        stopAutoscroll()
        guard let target = drag.target else { return cancelDrag() }
        self.drag = nil
        switch (drag.payload, target) {
        case let (.workspaces(ids), .position(position)):
            model.send(.reorder(ids, to: position))
        case let (.workspaces(ids), .intoGroup(group)):
            model.send(.move(ids, toGroup: group))
        case let (.group(group), .position(position)):
            model.send(.reorderGroup(group, index: position.index))
        case (.group, .intoGroup):
            break
        }
        // Rows land under the lifted view, stay hidden until it arrives.
        suppressed = drag.hiddenKeys
        reload(animated: true)
        land(drag)
    }

    private func cancelDrag() {
        guard let drag else { return }
        stopAutoscroll()
        self.drag = nil
        press?.cancelled = true
        suppressed = drag.hiddenKeys
        reload(animated: true)
        land(drag)
    }

    /// Flies the lifted view to its row's current frame, then swaps it out.
    private func land(_ drag: Drag) {
        let destination = displayed.row(for: drag.grabbedKey).map(frame(for:)) ?? drag.lift.frame
        drag.lift.setLifted(false, animated: true)
        Motion.animate(Motion.settle, {
            drag.lift.animator().frame = destination
        }, completion: { [weak self] in
            drag.lift.removeFromSuperview()
            guard let self else { return }
            self.suppressed.subtract(drag.hiddenKeys)
            for key in drag.hiddenKeys { self.rowViews[key]?.alphaValue = 1 }
            if let pillFrame = self.activePillFrame(in: self.displayed) {
                self.pill.frame = pillFrame
                self.pill.alphaValue = 1
            }
            self.updateHover()
        })
    }

    // MARK: Autoscroll

    private func startAutoscroll() {
        guard autoscrollLink == nil else { return }
        let link = displayLink(target: self, selector: #selector(autoscrollTick(_:)))
        link.add(to: .main, forMode: .common)
        autoscrollLink = link
    }

    private func stopAutoscroll() {
        autoscrollLink?.invalidate()
        autoscrollLink = nil
    }

    @objc private func autoscrollTick(_ link: CADisplayLink) {
        guard let windowPoint = drag?.lastWindowPoint ?? external?.windowPoint,
              let scrollView = enclosingScrollView else { return }
        let clip = scrollView.contentView
        let point = clip.convert(windowPoint, from: nil)
        let b = clip.bounds
        let zone = SidebarStyle.autoscrollZone
        let fromTop = point.y - b.minY
        let fromBottom = b.maxY - point.y
        var velocity: CGFloat = 0 // points per second
        if fromTop < zone { velocity = -pow((zone - max(fromTop, -zone)) / zone, 2) * 900 }
        else if fromBottom < zone { velocity = pow((zone - max(fromBottom, -zone)) / zone, 2) * 900 }
        guard velocity != 0 else { return }
        let dt = max(1.0 / 240, min(1.0 / 30, link.targetTimestamp - link.timestamp))
        let maxY = max(0, frame.height - b.height)
        let y = min(max(b.minY + velocity * dt, 0), maxY)
        guard y != b.minY else { return }
        clip.scroll(to: NSPoint(x: b.minX, y: y))
        scrollView.reflectScrolledClipView(clip)
        if drag != nil {
            updateDrag(windowPoint: windowPoint)
        } else if let external {
            _ = externalDragMoved(windowPoint: windowPoint, sourceMachine: external.sourceMachine)
        }
    }

    // MARK: - External tab drag

    private final class ExternalDrag {
        var proposal: SidebarTabDrop?
        var windowPoint: NSPoint
        var sourceMachine: MachineID?
        var springTarget: WorkspaceID?
        var springTask: Task<Void, Never>?

        init(windowPoint: NSPoint, sourceMachine: MachineID?) {
            self.windowPoint = windowPoint
            self.sourceMachine = sourceMachine
        }
    }

    /// Updates an external tab drag at a window point. Returns the proposal
    /// and its highlight rect in this view's coordinates, or nil when the
    /// point is outside the list or no drop is possible there.
    func externalDragMoved(windowPoint: NSPoint, sourceMachine: MachineID?) -> (SidebarTabDrop, NSRect)? {
        guard drag == nil, !model.isFiltering else { return nil }
        let point = convert(windowPoint, from: nil)
        guard visibleRect.contains(point) else {
            externalDragExited()
            return nil
        }
        let external = self.external ?? ExternalDrag(windowPoint: windowPoint, sourceMachine: sourceMachine)
        external.windowPoint = windowPoint
        external.sourceMachine = sourceMachine
        if self.external == nil {
            self.external = external
            setHovered(nil)
            startAutoscroll()
        }

        if let baseY = DropResolver.baseY(forDisplayY: point.y, gapY: displayed.gapY, gapHeight: displayed.gapShift) {
            let base = SidebarLayout.make(sections: model.sections, metrics: metrics, options: options(includeGap: false))
            let proposal = DropResolver.resolveTabDrop(y: baseY, base: base, sections: model.sections, sourceMachine: sourceMachine)
            if proposal != external.proposal {
                external.proposal = proposal
                reload(animated: true)
            }
        }
        updateSpringLoad(external)
        guard let proposal = external.proposal, let rect = highlightRect(for: proposal) else { return nil }
        return (proposal, rect)
    }

    func externalDragExited() {
        guard let external else { return }
        external.springTask?.cancel()
        self.external = nil
        stopAutoscroll()
        reload(animated: true)
    }

    /// Ends an external drag and returns what it would do. The App commits
    /// the proposal (one daemon command) and updates the model.
    func externalDragEnded() -> SidebarTabDrop? {
        let proposal = external?.proposal
        externalDragExited()
        return proposal
    }

    private func highlightRect(for proposal: SidebarTabDrop) -> NSRect? {
        switch proposal {
        case let .intoWorkspace(id):
            return displayed.row(for: .workspace(id)).map(frame(for:))
        case let .intoGroup(id):
            return displayed.row(for: .group(id)).map(frame(for:))
        case .newWorkspace:
            return displayed.gapY.map { NSRect(x: inset, y: $0, width: max(0, bounds.width - inset * 2), height: displayed.gapHeight) }
        }
    }

    /// Arc-style spring loading: hovering a row for `springLoadDelay` selects
    /// it so the user can keep dragging into that workspace's panes.
    private func updateSpringLoad(_ external: ExternalDrag) {
        let target: WorkspaceID? = if case let .intoWorkspace(id)? = external.proposal { id } else { nil }
        guard target != external.springTarget else { return }
        external.springTask?.cancel()
        external.springTarget = target
        guard let target, model.activeWorkspaceID != target else { return }
        let clock = springLoadClock
        let delay = springLoadDelay
        external.springTask = Task { [weak self] in
            do { try await clock.sleep(for: delay) } catch { return }
            guard let self, self.external === external, external.springTarget == target else { return }
            self.model.click(target)
            self.reload(animated: true)
        }
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .option, .shift, .control])
        if event.keyCode == 53 { // Escape
            if drag != nil { return cancelDrag() }
            if !model.filterText.isEmpty {
                model.filterText = ""
                reload(animated: true)
                return
            }
        }
        switch event.specialKey {
        case .upArrow?, .downArrow?:
            let up = event.specialKey == .upArrow
            if flags == [.command, .option] {
                model.moveSelection(up ? .up : .down)
            } else if flags.isEmpty || flags == .shift {
                model.moveActive(by: up ? -1 : 1, extending: flags == .shift, visibleOrder: visibleWorkspaceOrder)
            } else {
                return super.keyDown(with: event)
            }
            reload(animated: true)
            revealActive()
        case .carriageReturn?, .enter?:
            if let active = model.activeWorkspaceID { beginRename(.workspace(active)) }
        case .delete?, .deleteForward?:
            if flags == .command, !model.selection.isEmpty { model.send(.close(model.orderedSelection)) }
        default:
            if flags.subtracting(.shift).isEmpty, let chars = event.characters, !chars.isEmpty,
               chars.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) }) {
                onTypeToSearch?(chars)
            } else {
                super.keyDown(with: event)
            }
        }
    }

    // MARK: - Rename

    private struct Rename {
        var key: SidebarRowKey
        var field: NSTextField
        var original: String
        var cancelled = false
    }

    func beginRename(_ key: SidebarRowKey) {
        guard !compact, drag == nil else { return }
        if rename != nil { endRename(commit: true) }
        let original: String
        switch key {
        case let .workspace(id): original = workspaces[id]?.title ?? ""
        case let .group(id): original = groups[id]?.name ?? ""
        default: return
        }
        if let row = displayed.row(for: key) { scrollToVisible(frame(for: row)) }
        realizeVisibleRows()
        guard let view = rowViews[key] else { return }
        let titleFrame = convert(view.titleFrame, from: view)
        let field = NSTextField(string: original)
        field.font = view.titleFont
        field.isBordered = false
        field.drawsBackground = true
        field.backgroundColor = Palette.hoverFill
        field.textColor = Palette.textPrimary
        field.focusRingType = .none
        field.usesSingleLineMode = true
        field.lineBreakMode = .byClipping
        field.cell?.isScrollable = true
        field.delegate = self
        field.wantsLayer = true
        field.layer?.cornerRadius = 4
        let height = ceil(field.intrinsicContentSize.height)
        field.frame = NSRect(
            x: titleFrame.minX - 3,
            y: titleFrame.midY - height / 2,
            width: max(60, view.frame.maxX - titleFrame.minX - 8),
            height: height
        )
        addSubview(field)
        view.setTitleHidden(true)
        rename = Rename(key: key, field: field, original: original)
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    private func endRename(commit: Bool) {
        guard let rename else { return }
        self.rename = nil
        rename.field.delegate = nil
        rename.field.removeFromSuperview()
        rowViews[rename.key]?.setTitleHidden(false)
        let text = rename.field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if commit, !rename.cancelled, !text.isEmpty, text != rename.original {
            switch rename.key {
            case let .workspace(id): model.send(.rename(id, text))
            case let .group(id): model.send(.renameGroup(id, text))
            default: break
            }
            reload(animated: false)
        }
        window?.makeFirstResponder(self)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard rename?.field === control else { return false }
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            rename?.cancelled = true
            endRename(commit: false)
            return true
        }
        if selector == #selector(NSResponder.insertNewline(_:)) {
            endRename(commit: true)
            return true
        }
        return false
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField, rename?.field === field else { return }
        endRename(commit: true)
    }

    // MARK: - Context menu

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let menu = NSMenu()
        switch displayed.row(at: point.y)?.key {
        case let .workspace(id)?:
            if !model.selection.contains(id) {
                model.click(id)
                reload(animated: true)
            }
            buildWorkspaceMenu(menu, clicked: id)
        case let .group(id)?:
            buildGroupMenu(menu, group: id)
        case let .section(id)?:
            buildSectionMenu(menu, section: id)
        default:
            menu.addItem(item(Strings.newWorkspace) { [weak self] in self?.model.send(.newWorkspace(machine: nil, group: nil)) })
            menu.addItem(.separator())
            menu.addItem(presentationItem())
        }
        return menu
    }

    private func buildWorkspaceMenu(_ menu: NSMenu, clicked: WorkspaceID) {
        let ids = model.orderedSelection.isEmpty ? [clicked] : model.orderedSelection
        let pinnedIDs = Set(model.section(.pinned)?.workspaces.map(\.id) ?? [])
        let allPinned = ids.allSatisfy(pinnedIDs.contains)
        let location = SidebarEdits.locate(clicked, in: model.sections)
        let groupID: GroupID? = location.flatMap { loc in
            guard loc.child != nil, case let .group(g) = model.sections[loc.section].nodes[loc.node] else { return nil }
            return g.id
        }

        if ids.count == 1 {
            menu.addItem(item(Strings.rename) { [weak self] in self?.beginRename(.workspace(clicked)) })
        }
        menu.addItem(item(allPinned ? Strings.unpin : Strings.pin) { [weak self] in
            self?.model.send(.setPinned(ids, !allPinned))
        })
        menu.addItem(.separator())

        if let loc = location, model.sections[loc.section].machine != nil {
            menu.addItem(item(Strings.newGroupFromSelection) { [weak self] in
                self?.model.send(.createGroup(GroupID.make(), name: Strings.defaultGroupName, color: .gray, workspaces: ids))
            })
            let sectionGroups = model.sections[loc.section].nodes.compactMap { node -> SidebarGroup? in
                if case let .group(g) = node, g.id != groupID { return g }
                return nil
            }
            if !sectionGroups.isEmpty {
                let sub = NSMenu()
                for group in sectionGroups {
                    let entry = item(group.name) { [weak self] in self?.model.send(.move(ids, toGroup: group.id)) }
                    entry.image = SidebarStyle.swatchImage(group.color)
                    sub.addItem(entry)
                }
                let parent = NSMenuItem(title: Strings.moveToGroup, action: nil, keyEquivalent: "")
                parent.submenu = sub
                menu.addItem(parent)
            }
            if let groupID, let s = SidebarEdits.locateGroup(groupID, in: model.sections) {
                menu.addItem(item(Strings.removeFromGroup) { [weak self] in
                    guard let self else { return }
                    self.model.send(.reorder(ids, to: DropPosition(section: self.model.sections[s.section].id, index: s.node + 1)))
                })
            }
            menu.addItem(.separator())
        }

        let colors = NSMenu()
        colors.addItem(item(Strings.noColor, image: SidebarStyle.swatchImage(nil)) { [weak self] in self?.model.send(.setColor(ids, nil)) })
        for color in SidebarColor.allCases {
            colors.addItem(item(Strings.color(color), image: SidebarStyle.swatchImage(color)) { [weak self] in self?.model.send(.setColor(ids, color)) })
        }
        let colorItem = NSMenuItem(title: Strings.color, action: nil, keyEquivalent: "")
        colorItem.submenu = colors
        menu.addItem(colorItem)

        let icons = NSMenu()
        for choice in Strings.iconChoices {
            let image = NSImage(systemSymbolName: choice.symbol, accessibilityDescription: nil)
            icons.addItem(item(choice.label, image: image) { [weak self] in self?.model.send(.setIcon(ids, .symbol(choice.symbol))) })
        }
        let iconItem = NSMenuItem(title: Strings.icon, action: nil, keyEquivalent: "")
        iconItem.submenu = icons
        menu.addItem(iconItem)

        menu.addItem(.separator())
        menu.addItem(item(ids.count > 1 ? Strings.closeMany(ids.count) : Strings.close) { [weak self] in
            self?.model.send(.close(ids))
        })
    }

    private func buildGroupMenu(_ menu: NSMenu, group: GroupID) {
        guard let g = groups[group] else { return }
        menu.addItem(item(Strings.renameGroup) { [weak self] in self?.beginRename(.group(group)) })
        let colors = NSMenu()
        for color in SidebarColor.allCases {
            let entry = item(Strings.color(color), image: SidebarStyle.swatchImage(color)) { [weak self] in
                self?.model.send(.setGroupColor(group, color))
            }
            entry.state = g.color == color ? .on : .off
            colors.addItem(entry)
        }
        let colorItem = NSMenuItem(title: Strings.color, action: nil, keyEquivalent: "")
        colorItem.submenu = colors
        menu.addItem(colorItem)
        menu.addItem(item(g.isCollapsed ? Strings.expand : Strings.collapse) { [weak self] in
            self?.model.send(.toggleCollapse(.group(group)))
        })
        menu.addItem(.separator())
        let machine = g.workspaces.first?.machineID
        menu.addItem(item(Strings.newWorkspaceInGroup) { [weak self] in
            self?.model.send(.newWorkspace(machine: machine, group: group))
        })
        menu.addItem(item(Strings.ungroup) { [weak self] in self?.model.send(.ungroup(group)) })
    }

    private func buildSectionMenu(_ menu: NSMenu, section: SectionID) {
        guard let s = sections[section] else { return }
        if let machine = s.machine {
            menu.addItem(item(Strings.newWorkspaceOnMachine(machine.name)) { [weak self] in
                self?.model.send(.newWorkspace(machine: machine.id, group: nil))
            })
        }
        menu.addItem(item(s.isCollapsed ? Strings.expand : Strings.collapse) { [weak self] in
            self?.model.send(.toggleCollapse(.section(section)))
        })
        menu.addItem(.separator())
        menu.addItem(presentationItem())
    }

    private func presentationItem() -> NSMenuItem {
        item(compact ? Strings.showFull : Strings.showIconsOnly) { [weak self] in self?.model.togglePresentation() }
    }

    private func item(_ title: String, image: NSImage? = nil, _ action: @escaping () -> Void) -> NSMenuItem {
        let item = MenuActions.item(title, action)
        item.image = image
        return item
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool { true }
}

/// Runs menu-item closures stored in `representedObject`; keeps menus
/// declarative without subclassing NSMenuItem.
final class MenuActions: NSObject {
    static let shared = MenuActions()

    final class Box {
        let handler: () -> Void
        init(_ handler: @escaping () -> Void) { self.handler = handler }
    }

    static func item(_ title: String, _ handler: @escaping () -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(run(_:)), keyEquivalent: "")
        item.target = shared
        item.representedObject = Box(handler)
        return item
    }

    @objc func run(_ sender: NSMenuItem) {
        (sender.representedObject as? Box)?.handler()
    }
}
