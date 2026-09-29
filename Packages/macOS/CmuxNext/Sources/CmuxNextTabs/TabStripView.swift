public import AppKit
import CmuxNextDesign
import Observation
import QuartzCore

/// Chrome-style tab strip for one pane.
///
/// Reads a `TabStripModel`, lays tabs out with `TabLayoutEngine`, and animates
/// between layouts with per-tab springs on a display link, so open, close,
/// reorder, and scroll all retarget smoothly mid-flight. All user actions go
/// out as `TabStripIntent`s through `model.send`; the strip never edits the
/// model itself.
public final class TabStripView: NSView {
    public enum Background: Sendable {
        case none
        /// One Liquid Glass panel behind all tabs.
        case glass
    }

    /// Height the strip is designed for.
    public static let preferredHeight: CGFloat = 36

    public let model: TabStripModel

    public weak var previewProvider: (any TabPreviewProvider)? {
        didSet { hoverCard.previewProvider = previewProvider }
    }

    public var metrics: TabStripMetrics = .standard {
        didSet {
            guard metrics != oldValue else { return }
            hoverCard.metrics = metrics
            for view in tabViews.values { view.metrics = metrics }
            relayout(animated: false)
        }
    }

    public var hoverCardPolicy: HoverCardPolicy {
        get { hoverCard.policy }
        set { hoverCard.policy = newValue }
    }

    /// Dragging empty strip space moves the window (titlebar strips).
    public var dragsWindowFromEmptySpace = true

    // MARK: Views

    private var glassView: NSGlassEffectView?
    private let contentView = FlippedView()
    private let tabsClip = FlippedView()
    private let fadeMask = CAGradientLayer()
    private let newTabButton = NewTabButtonView()
    let hoverCard = TabHoverCardController()
    private var trackingArea: NSTrackingArea?

    // MARK: Layout and animation state

    private struct Motion {
        var x: Spring
        var width: Spring
        var alpha: Spring

        init(x: CGFloat, width: CGFloat, alpha: CGFloat) {
            self.x = Spring(value: x)
            self.width = Spring(value: width)
            self.alpha = Spring(value: alpha, response: 0.2, dampingRatio: 1)
        }

        var isSettled: Bool { x.isSettled && width.isSettled && alpha.isSettled }

        mutating func snap() {
            x.snap()
            width.snap()
            alpha.snap()
        }
    }

    private var tabViews: [TabID: TabView] = [:]
    private var motion: [TabID: Motion] = [:]
    private var dying: Set<TabID> = []
    /// Tabs in visual order, excluding dying and torn-out tabs.
    private var displayed: [TabItem] = []
    private var result = TabLayoutResult(slots: [], contentWidth: 0, standardWidth: 0, availableWidth: 0)
    private var scroll = Spring(value: 0, response: 0.32, dampingRatio: 1)
    private var closingModeWidth: CGFloat?
    private var hasSynced = false
    private var lastSelectedID: TabID?
    private var lastModelOrder: [TabID] = []
    private var lastStyle: TabStripStyle?
    private var lastViewportWidth: CGFloat = -1
    private var displayLink: CADisplayLink?
    private var lastFrameTime: CFTimeInterval?
    private var observationTask: Task<Void, Never>?

    // MARK: Pointer state

    private var hoveredID: TabID?
    private var closeHoveredID: TabID?
    private var pressedCloseID: TabID?
    private var middlePressID: TabID?
    private var pressedNewTab = false
    private var hoverCardSuppressed = false

    private struct Press {
        var id: TabID
        var start: CGPoint
    }

    private struct Drag {
        var id: TabID
        var grabOffset: CGFloat
        var originalIndex: Int
        var currentIndex: Int
        var isPinned: Bool
        var lastPoint: CGPoint
    }

    private var press: Press?
    private var drag: Drag?
    /// Order shown after a local reorder until the model's order changes.
    private var orderOverride: [TabID]?
    /// Tab torn out of this strip and handed to the App's drag session. Its
    /// slot stays collapsed until the model drops it or the App restores it.
    private var detachedID: TabID?
    /// Display index of the phantom gap shown for an external drag.
    private var dropPlaceholderIndex: Int?
    /// Pointer of the external drag, in view coordinates, for edge autoscroll.
    private var phantomPoint: CGPoint?
    private var escapeMonitor: Any?
    /// A dropped tab keeps the placeholder's geometry when it arrives.
    private var pendingDrop: (id: TabID, x: CGFloat, width: CGFloat)?
    private static let placeholderID = TabID("__cmux.tabs.drop-placeholder__")

    // MARK: - Init

    public init(model: TabStripModel, background: Background = .none) {
        self.model = model
        super.init(frame: CGRect(x: 0, y: 0, width: 600, height: Self.preferredHeight))
        wantsLayer = true
        layerContentsRedrawPolicy = .never

        switch background {
        case .none:
            addSubview(contentView)
        case .glass:
            let glass = Glass.makePanel(content: contentView, cornerRadius: Metrics.itemCornerRadius + 4)
            glass.translatesAutoresizingMaskIntoConstraints = true
            addSubview(glass)
            glassView = glass
        }
        contentView.wantsLayer = true
        tabsClip.wantsLayer = true
        tabsClip.layer?.masksToBounds = true
        fadeMask.startPoint = CGPoint(x: 0, y: 0.5)
        fadeMask.endPoint = CGPoint(x: 1, y: 0.5)
        fadeMask.actions = ["bounds": NSNull(), "position": NSNull(), "colors": NSNull(), "locations": NSNull()]
        contentView.addSubview(tabsClip)
        contentView.addSubview(newTabButton)
        newTabButton.onPress = { [weak self] in self?.model.send(.newTab(after: nil)) }

        setAccessibilityElement(true)
        setAccessibilityRole(.tabGroup)
        setAccessibilityLabel(Strings.axStrip)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    public override var isFlipped: Bool { true }
    public override var mouseDownCanMoveWindow: Bool { false }
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    public override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: Self.preferredHeight)
    }

    // Every event is handled here, never by a tab subview.
    public override func hitTest(_ point: NSPoint) -> NSView? {
        let local = superview.map { convert(point, from: $0) } ?? point
        return bounds.contains(local) ? self : nil
    }

    public override func accessibilityChildren() -> [Any]? {
        displayed.compactMap { tabViews[$0.id] } + (newTabButton.isHidden ? [] : [newTabButton])
    }

    // MARK: - Lifecycle

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            startObserving()
            sync(fromModel: true)
        } else {
            observationTask?.cancel()
            observationTask = nil
            displayLink?.invalidate()
            displayLink = nil
            lastFrameTime = nil
            hoverCard.hide(allowsQuickReshow: false)
            removeEscapeMonitor()
        }
    }

    private func startObserving() {
        guard observationTask == nil else { return }
        let model = model
        observationTask = Task { [weak self] in
            let changes = Observations {
                ModelSnapshot(tabs: model.tabs, selectedID: model.selectedID, style: model.style, showsNewTabButton: model.showsNewTabButton)
            }
            for await _ in changes {
                guard let self else { return }
                self.sync(fromModel: true)
            }
        }
    }

    private struct ModelSnapshot: Sendable {
        var tabs: [TabItem]
        var selectedID: TabID?
        var style: TabStripStyle
        var showsNewTabButton: Bool
    }

    public override func layout() {
        super.layout()
        glassView?.frame = bounds
        if glassView == nil { contentView.frame = bounds }
        let showsButton = model.showsNewTabButton
        let padding = metrics.stripHorizontalPadding
        let viewport = max(0, bounds.width - 2 * padding - (showsButton ? metrics.newTabButtonWidth : 0))
        tabsClip.frame = CGRect(x: padding, y: 0, width: viewport, height: bounds.height)
        if viewport != lastViewportWidth {
            lastViewportWidth = viewport
            // Chrome resizes tabs with the window instantly.
            relayout(animated: false)
        } else {
            applyFrames()
        }
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    private var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    private var viewportWidth: CGFloat { tabsClip.bounds.width }

    // MARK: - Model sync

    private func sync(fromModel: Bool) {
        let modelOrdered = model.orderedTabs
        if fromModel {
            let order = modelOrdered.map(\.id)
            if order != lastModelOrder {
                // The App applied (or overrode) our reorder, or tabs came and went.
                orderOverride = nil
                if let detachedID, !order.contains(detachedID) { self.detachedID = nil }
                if let pendingDrop, !order.contains(pendingDrop.id) {
                    self.pendingDrop = nil
                    dropPlaceholderIndex = nil
                }
                lastModelOrder = order
            }
        }

        var ordered = modelOrdered.filter { $0.id != detachedID }
        if let override = orderOverride {
            if Set(override) == Set(ordered.map(\.id)) {
                let byID = Dictionary(uniqueKeysWithValues: ordered.map { ($0.id, $0) })
                ordered = override.compactMap { byID[$0] }
            } else {
                orderOverride = nil
            }
        }

        let animated = hasSynced && !reduceMotion
        let ids = Set(ordered.map(\.id))
        for (id, view) in tabViews where !ids.contains(id) && !dying.contains(id) {
            if animated {
                dying.insert(id)
                motion[id]?.width.target = 0
                motion[id]?.alpha.target = 0
                view.showsSeparator = false
                view.isHovered = false
            } else {
                removeTab(id)
            }
        }

        var added: Set<TabID> = []
        for item in ordered {
            if let view = tabViews[item.id] {
                dying.remove(item.id)
                view.update(item: item)
                // A torn-out tab dropped back here takes the drop gap's geometry.
                if pendingDrop?.id == item.id { added.insert(item.id) }
            } else {
                let view = TabView(item: item)
                view.style = model.style
                view.metrics = metrics
                let id = item.id
                view.onAccessibilityPress = { [weak self] in self?.model.send(.select(id)) }
                view.onAccessibilityClose = { [weak self] in self?.close(id, source: .accessibility) }
                tabsClip.addSubview(view)
                tabViews[id] = view
                motion[id] = Motion(x: 0, width: 0, alpha: animated ? 0 : 1)
                added.insert(id)
            }
        }
        if hasSynced, !added.isEmpty { closingModeWidth = nil }

        if pendingDrop.map({ ids.contains($0.id) }) == true {
            dropPlaceholderIndex = nil
        }

        displayed = ordered
        let styleChanged = lastStyle != nil && lastStyle != model.style
        lastStyle = model.style
        for item in displayed {
            let view = tabViews[item.id]
            view?.isSelected = item.id == model.selectedID
            view?.style = model.style
        }
        if newTabButton.isHidden == model.showsNewTabButton {
            newTabButton.isHidden = !model.showsNewTabButton
            needsLayout = true
        }

        relayout(animated: animated || (styleChanged && !reduceMotion), added: added)

        let selected = model.selectedID
        if let selected, selected != lastSelectedID || added.contains(selected) {
            reveal(selected, animated: animated)
        }
        lastSelectedID = selected

        if let hoveredID {
            if let item = model.tab(hoveredID) {
                hoverCard.refresh(item)
            } else {
                setHovered(nil)
                hoverCard.hide()
            }
        }
        hasSynced = true
    }

    private func removeTab(_ id: TabID) {
        tabViews[id]?.removeFromSuperview()
        tabViews[id] = nil
        motion[id] = nil
        dying.remove(id)
        if hoveredID == id { hoveredID = nil }
        if closeHoveredID == id { closeHoveredID = nil }
    }

    // MARK: - Layout

    private func layoutItems() -> [TabLayoutItem] {
        var items = displayed.map { TabLayoutItem(id: $0.id, isPinned: $0.isPinned, isSelected: $0.id == model.selectedID) }
        if let drag, let from = items.firstIndex(where: { $0.id == drag.id }) {
            let item = items.remove(at: from)
            items.insert(item, at: min(max(drag.currentIndex, 0), items.count))
        }
        if let index = dropPlaceholderIndex {
            let pinnedCount = items.count(where: \.isPinned)
            items.insert(TabLayoutItem(id: Self.placeholderID), at: min(max(index, pinnedCount), items.count))
        }
        return items
    }

    private func relayout(animated: Bool, added: Set<TabID> = []) {
        result = TabLayoutEngine.layout(
            items: layoutItems(),
            availableWidth: viewportWidth,
            style: model.style,
            metrics: metrics,
            closingModeWidth: closingModeWidth
        )
        for slot in result.slots where slot.id != Self.placeholderID {
            guard var m = motion[slot.id] else { continue }
            if added.contains(slot.id) {
                if let pendingDrop, pendingDrop.id == slot.id {
                    m = Motion(x: pendingDrop.x, width: pendingDrop.width, alpha: 1)
                    self.pendingDrop = nil
                } else {
                    // New tabs grow in from zero width at their slot.
                    m = Motion(x: slot.x, width: animated ? 0 : slot.width, alpha: animated ? 0 : 1)
                }
            }
            if drag?.id != slot.id { m.x.target = slot.x }
            m.width.target = slot.width
            m.alpha.target = 1
            if !animated { m.snap() }
            motion[slot.id] = m
        }
        scroll.target = TabScrollMath.clamp(scroll.target, contentWidth: result.contentWidth, viewportWidth: viewportWidth)
        if !animated {
            scroll.snap()
            for id in dying { removeTab(id) }
        }
        updateSeparators()
        startAnimating()
        applyFrames()
    }

    private func reveal(_ id: TabID, animated: Bool) {
        guard let slot = result.slot(id) else { return }
        scroll.target = TabScrollMath.offset(
            revealing: slot,
            current: scroll.target,
            contentWidth: result.contentWidth,
            viewportWidth: viewportWidth,
            margin: metrics.scrollFadeWidth
        )
        if !animated || reduceMotion { scroll.snap() }
        startAnimating()
    }

    private func updateSeparators() {
        let slots = result.slots
        let selected = model.selectedID
        func emphasized(_ id: TabID) -> Bool {
            id == selected || id == hoveredID || id == drag?.id || id == Self.placeholderID
        }
        for (index, slot) in slots.enumerated() {
            guard let view = tabViews[slot.id] else { continue }
            guard index + 1 < slots.count else {
                view.showsSeparator = false
                continue
            }
            let next = slots[index + 1]
            view.showsSeparator = !emphasized(slot.id) && !emphasized(next.id) && slot.isPinned == next.isPinned
        }
    }

    private func applyFrames() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let tabHeight = max(0, bounds.height - 2 * metrics.stripVerticalPadding)
        let offset = scroll.value
        var trailing: CGFloat = 0
        for (id, view) in tabViews {
            guard let m = motion[id] else { continue }
            let width = max(0, m.width.value)
            let frame = CGRect(x: m.x.value - offset, y: metrics.stripVerticalPadding, width: width, height: tabHeight)
            if view.frame != frame {
                let resized = view.frame.size != frame.size
                view.frame = frame
                if resized { view.layoutLayers() }
            }
            view.layer?.opacity = Float(min(max(m.alpha.value, 0), 1))
            trailing = max(trailing, m.x.value + width)
        }
        let buttonWidth = metrics.newTabButtonWidth
        let buttonX = tabsClip.frame.minX + min(trailing - offset, viewportWidth)
        newTabButton.frame = CGRect(x: buttonX, y: metrics.stripVerticalPadding, width: buttonWidth, height: tabHeight)
        updateFadeMask()
    }

    private func updateFadeMask() {
        let width = viewportWidth
        let edges = TabScrollMath.fadedEdges(offset: scroll.value, contentWidth: result.contentWidth, viewportWidth: width)
        guard width > 0, edges.leading || edges.trailing else {
            if tabsClip.layer?.mask != nil { tabsClip.layer?.mask = nil }
            return
        }
        let fade = min(metrics.scrollFadeWidth / width, 0.5)
        fadeMask.frame = tabsClip.bounds
        let opaque = NSColor.black.cgColor
        let clear = NSColor.clear.cgColor
        fadeMask.colors = [edges.leading ? clear : opaque, opaque, opaque, edges.trailing ? clear : opaque]
        fadeMask.locations = [0, NSNumber(value: Double(fade)), NSNumber(value: Double(1 - fade)), 1]
        if tabsClip.layer?.mask !== fadeMask { tabsClip.layer?.mask = fadeMask }
    }

    // MARK: - Animation

    private func startAnimating() {
        guard window != nil else { return }
        if displayLink == nil {
            let link = displayLink(target: self, selector: #selector(displayLinkFired(_:)))
            link.add(to: .main, forMode: .common)
            displayLink = link
        }
        displayLink?.isPaused = false
    }

    @objc private func displayLinkFired(_ link: CADisplayLink) {
        let now = link.timestamp
        let dt = lastFrameTime.map { CGFloat(now - $0) } ?? (1.0 / 120.0)
        lastFrameTime = now
        advance(dt)
    }

    private func advance(_ dt: CGFloat) {
        var active = false
        for id in Array(motion.keys) {
            guard var m = motion[id] else { continue }
            if drag?.id == id { m.x.snap() }
            m.x.step(dt)
            m.width.step(dt)
            m.alpha.step(dt)
            motion[id] = m
            if dying.contains(id), m.width.isSettled, m.alpha.isSettled {
                removeTab(id)
            } else if !m.isSettled {
                active = true
            }
        }
        if autoscrollDuringDrag(dt) { active = true }
        scroll.step(dt)
        if !scroll.isSettled { active = true }
        applyFrames()
        if drag == nil, pressedCloseID == nil, let window {
            // Tabs sliding under a still pointer update hover, as in Chrome.
            let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
            if bounds.contains(point) { updateHover(at: point) }
        }
        if !active {
            displayLink?.isPaused = true
            lastFrameTime = nil
        }
    }

    // MARK: - Hit testing

    private func tabID(at point: CGPoint) -> TabID? {
        let local = convert(point, to: tabsClip)
        guard local.x >= 0, local.x <= tabsClip.bounds.width else { return nil }
        for item in displayed {
            guard let view = tabViews[item.id] else { continue }
            let frame = view.frame
            if local.x >= frame.minX, local.x < frame.maxX, local.y >= frame.minY - metrics.stripVerticalPadding,
               local.y <= frame.maxY + metrics.stripVerticalPadding {
                return item.id
            }
        }
        return nil
    }

    private func isInCloseButton(_ id: TabID, _ point: CGPoint) -> Bool {
        guard let view = tabViews[id], let rect = view.closeButtonRect else { return false }
        return rect.insetBy(dx: -2, dy: -2).contains(convert(point, to: view))
    }

    private func isInNewTabButton(_ point: CGPoint) -> Bool {
        !newTabButton.isHidden && newTabButton.frame.contains(convert(point, to: contentView))
    }

    // MARK: - Hover

    private func setHovered(_ id: TabID?) {
        guard id != hoveredID else { return }
        if let hoveredID { tabViews[hoveredID]?.isHovered = false }
        hoveredID = id
        if let id { tabViews[id]?.isHovered = true }
        updateSeparators()
    }

    private func updateHover(at point: CGPoint) {
        let id = drag == nil ? tabID(at: point) : nil
        setHovered(id)
        let closeID = id.flatMap { isInCloseButton($0, point) ? $0 : nil }
        if closeID != closeHoveredID {
            if let closeHoveredID { tabViews[closeHoveredID]?.isCloseHovered = false }
            closeHoveredID = closeID
            if let closeID { tabViews[closeID]?.isCloseHovered = true }
        }
        newTabButton.isHovered = drag == nil && isInNewTabButton(point)

        guard !hoverCardSuppressed else { return }
        if let id, let item = model.tab(id), let view = tabViews[id], let window, NSApp.isActive {
            let anchor = window.convertToScreen(view.convert(view.bounds, to: nil))
            hoverCard.hover(item, anchor: anchor, tabWidth: view.bounds.width, parent: window)
        } else {
            hoverCard.hide()
        }
    }

    public override func mouseEntered(with event: NSEvent) {
        updateHover(at: convert(event.locationInWindow, from: nil))
    }

    public override func mouseMoved(with event: NSEvent) {
        hoverCardSuppressed = false
        updateHover(at: convert(event.locationInWindow, from: nil))
    }

    public override func mouseExited(with event: NSEvent) {
        setHovered(nil)
        if let closeHoveredID { tabViews[closeHoveredID]?.isCloseHovered = false }
        closeHoveredID = nil
        newTabButton.isHovered = false
        hoverCard.hide()
        hoverCardSuppressed = false
        if closingModeWidth != nil, drag == nil {
            // Chrome's deferred relayout: tabs resize once the pointer leaves.
            closingModeWidth = nil
            relayout(animated: !reduceMotion)
        }
    }

    // MARK: - Clicks

    public override func mouseDown(with event: NSEvent) {
        hoverCard.hide(allowsQuickReshow: false)
        hoverCardSuppressed = true
        let point = convert(event.locationInWindow, from: nil)
        if isInNewTabButton(point) {
            pressedNewTab = true
            newTabButton.isPressed = true
            return
        }
        if let id = tabID(at: point) {
            if isInCloseButton(id, point) {
                pressedCloseID = id
                tabViews[id]?.isClosePressed = true
                return
            }
            // Chrome selects on mouse down.
            if model.selectedID != id { model.send(.select(id)) }
            press = Press(id: id, start: point)
            return
        }
        if event.clickCount == 2 {
            model.send(.newTab(after: nil))
            return
        }
        if dragsWindowFromEmptySpace { window?.performDrag(with: event) }
    }

    public override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let id = pressedCloseID {
            tabViews[id]?.isClosePressed = isInCloseButton(id, point)
            return
        }
        if pressedNewTab {
            newTabButton.isPressed = isInNewTabButton(point)
            return
        }
        if drag != nil {
            updateDrag(at: point, event: event)
            return
        }
        if let press, hypot(point.x - press.start.x, point.y - press.start.y) > 3 {
            beginDrag(press)
            updateDrag(at: point, event: event)
        }
    }

    public override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let id = pressedCloseID {
            pressedCloseID = nil
            tabViews[id]?.isClosePressed = false
            if isInCloseButton(id, point) { close(id, source: .mouse) }
            return
        }
        if pressedNewTab {
            pressedNewTab = false
            newTabButton.isPressed = false
            if isInNewTabButton(point) { model.send(.newTab(after: nil)) }
            return
        }
        if drag != nil { endDrag() }
        press = nil
        updateHover(at: point)
    }

    public override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2 else { return super.otherMouseDown(with: event) }
        hoverCard.hide(allowsQuickReshow: false)
        middlePressID = tabID(at: convert(event.locationInWindow, from: nil))
    }

    public override func otherMouseUp(with event: NSEvent) {
        guard event.buttonNumber == 2 else { return super.otherMouseUp(with: event) }
        let id = tabID(at: convert(event.locationInWindow, from: nil))
        if let id, id == middlePressID { close(id, source: .middleClick) }
        middlePressID = nil
    }

    public override func menu(for event: NSEvent) -> NSMenu? {
        hoverCard.hide(allowsQuickReshow: false)
        let point = convert(event.locationInWindow, from: nil)
        if let id = tabID(at: point), let item = model.tab(id) {
            return TabContextMenu.menu(for: item, in: model)
        }
        return TabContextMenu.emptySpaceMenu(in: model)
    }

    public override func scrollWheel(with event: NSEvent) {
        guard result.isOverflowing else { return super.scrollWheel(with: event) }
        var delta = event.scrollingDeltaX
        // Vertical wheels scroll the strip too, as in Chrome.
        if abs(event.scrollingDeltaY) > abs(delta) { delta = event.scrollingDeltaY }
        if !event.hasPreciseScrollingDeltas { delta *= 12 }
        scroll.snap(to: TabScrollMath.clamp(scroll.value - delta, contentWidth: result.contentWidth, viewportWidth: viewportWidth))
        hoverCard.hide(allowsQuickReshow: false)
        applyFrames()
    }

    /// Closes a tab. Mouse closes enter Chrome's closing mode first.
    private func close(_ id: TabID, source: TabCloseSource) {
        if source.entersClosingMode {
            closingModeWidth = TabLayoutEngine.closingModeWidth(afterClosing: id, in: result, current: closingModeWidth)
        }
        model.send(.close(id, source: source))
    }

    // MARK: - Drag reorder

    private func beginDrag(_ press: Press) {
        guard let index = displayed.firstIndex(where: { $0.id == press.id }), let m = motion[press.id] else { return }
        let contentX = convert(press.start, to: tabsClip).x + scroll.value
        drag = Drag(
            id: press.id,
            grabOffset: contentX - m.x.value,
            originalIndex: index,
            currentIndex: index,
            isPinned: displayed[index].isPinned,
            lastPoint: press.start
        )
        self.press = nil
        setHovered(nil)
        hoverCard.hide(allowsQuickReshow: false)
        tabViews[press.id]?.isLifted = true
        installEscapeMonitor()
        updateSeparators()
    }

    private func updateDrag(at point: CGPoint, event: NSEvent?) {
        guard var drag else { return }
        if let event, point.y < -metrics.tearOffDistance || point.y > bounds.height + metrics.tearOffDistance {
            handOffDrag(event: event)
            return
        }
        drag.lastPoint = point
        let group = result.slots.filter { $0.isPinned == drag.isPinned && $0.id != Self.placeholderID }
        guard let first = group.first, let last = group.last, let width = motion[drag.id]?.width.target else { return }
        let contentX = convert(point, to: tabsClip).x + scroll.value
        let x = min(max(contentX - drag.grabOffset, first.x), last.maxX - width)
        let others = group.filter { $0.id != drag.id }.map(\.width)
        let groupIndex = TabReorderMath.insertionIndex(draggedMinX: x, groupStart: first.x, otherWidths: others)
        let index = (drag.isPinned ? 0 : displayed.count(where: \.isPinned)) + groupIndex
        motion[drag.id]?.x.snap(to: x)
        let moved = index != drag.currentIndex
        drag.currentIndex = index
        self.drag = drag
        if moved {
            relayout(animated: !reduceMotion)
        } else {
            applyFrames()
            startAnimating()
        }
    }

    /// Scrolls an overflowing strip while a dragged tab sits in an edge fade.
    private func autoscrollDuringDrag(_ dt: CGFloat) -> Bool {
        guard let point = drag?.lastPoint ?? phantomPoint, result.isOverflowing else { return false }
        let local = convert(point, to: tabsClip).x
        let edge = metrics.scrollFadeWidth
        var speed: CGFloat = 0
        if local < edge { speed = -(edge - local) * 14 }
        if local > viewportWidth - edge { speed = (local - (viewportWidth - edge)) * 14 }
        guard speed != 0 else { return false }
        let target = TabScrollMath.clamp(scroll.value + speed * dt, contentWidth: result.contentWidth, viewportWidth: viewportWidth)
        guard target != scroll.value else { return false }
        scroll.snap(to: target)
        if let drag {
            updateDrag(at: drag.lastPoint, event: nil)
        } else if dropPlaceholderIndex != nil {
            let index = phantomIndex(at: point)
            if index != dropPlaceholderIndex {
                dropPlaceholderIndex = index
                relayout(animated: !reduceMotion)
            }
        }
        return true
    }

    private func endDrag() {
        guard let drag else { return }
        self.drag = nil
        removeEscapeMonitor()
        tabViews[drag.id]?.isLifted = false
        if drag.currentIndex != drag.originalIndex {
            var ids = displayed.map(\.id)
            ids.remove(at: drag.originalIndex)
            ids.insert(drag.id, at: min(drag.currentIndex, ids.count))
            orderOverride = ids
            let byID = Dictionary(uniqueKeysWithValues: displayed.map { ($0.id, $0) })
            displayed = ids.compactMap { byID[$0] }
            model.send(.reorder(drag.id, from: drag.originalIndex, to: drag.currentIndex))
        }
        relayout(animated: !reduceMotion)
    }


    /// Escape during an in-strip drag springs the tab back to where it started.
    private func cancelDrag() {
        guard var drag else { return }
        drag.currentIndex = drag.originalIndex
        self.drag = drag
        endDrag()
    }

    private func installEscapeMonitor() {
        guard escapeMonitor == nil else { return }
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53, let self, self.drag != nil else { return event }
            self.cancelDrag()
            return nil
        }
    }

    private func removeEscapeMonitor() {
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        escapeMonitor = nil
    }

    // MARK: - Hand-off to the App's drag session

    /// Dragging a tab past the tear-off distance hands it to the App's
    /// `TabDragSession` through `.dragBegan`. The strip collapses the slot and
    /// stops tracking; the session tracks the pointer itself from here.
    private func handOffDrag(event: NSEvent) {
        guard let drag, let view = tabViews[drag.id], let window else { return }
        let frameInWindow = view.convert(view.bounds, to: nil)
        let screenFrame = window.convertToScreen(frameInWindow)
        let pointer = window.convertPoint(toScreen: event.locationInWindow)
        let start = TabDragStart(
            tabID: drag.id,
            stripID: model.stripID,
            screenFrame: screenFrame,
            grabOffset: CGPoint(x: pointer.x - screenFrame.minX, y: pointer.y - screenFrame.minY),
            screenPoint: pointer,
            snapshot: snapshot(of: view)
        )
        self.drag = nil
        removeEscapeMonitor()
        view.isLifted = false
        detachedID = drag.id
        sync(fromModel: false)
        model.send(.dragBegan(start))
    }

    private func snapshot(of view: TabView) -> TabImage? {
        guard let layer = view.layer else { return nil }
        let scale = window?.backingScaleFactor ?? 2
        let size = view.bounds.size
        let width = Int((size.width * scale).rounded())
        let height = Int((size.height * scale).rounded())
        guard width > 0, height > 0, let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        // Layers are flipped; CoreGraphics is not.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: scale, y: -scale)
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            context.setFillColor(Palette.windowBackground.cgColor)
        }
        let radius = Metrics.itemCornerRadius
        context.addPath(CGPath(roundedRect: CGRect(origin: .zero, size: size).insetBy(dx: metrics.tabBackgroundInset, dy: 0), cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.fillPath()
        layer.render(in: context)
        return context.makeImage().map(TabImage.init)
    }

    /// Restores a tab this strip handed off (drag cancelled). It grows back
    /// into its slot. No-op when `id` is not the detached tab.
    public func restoreDetachedTab(_ id: TabID) {
        guard detachedID == id else { return }
        detachedID = nil
        sync(fromModel: false)
    }

    // MARK: - Phantom tab for external drags

    /// Where a dragged tab would land if dropped at `screenPoint`, or nil
    /// when the point is not over this strip. Pure query: opens no gap.
    ///
    /// `index` is a position in `model.orderedTabs` without the tab this strip
    /// handed off (if any), which is the final index for a move command.
    /// `ghostFrame` is the screen frame of the inline slot, for the session's
    /// ghost to collapse into.
    public func dropTarget(atScreenPoint screenPoint: CGPoint, verticalSlop: CGFloat = 10) -> TabStripDropTarget? {
        guard let window, !isHiddenOrHasHiddenAncestor else { return nil }
        let point = convert(window.convertPoint(fromScreen: screenPoint), from: nil)
        guard point.x >= 0, point.x <= bounds.width, point.y >= -verticalSlop, point.y <= bounds.height + verticalSlop else {
            return nil
        }
        let index = phantomIndex(at: point)
        var items = displayed.map { TabLayoutItem(id: $0.id, isPinned: $0.isPinned, isSelected: $0.id == model.selectedID) }
        items.insert(TabLayoutItem(id: Self.placeholderID), at: min(index, items.count))
        let layout = TabLayoutEngine.layout(items: items, availableWidth: viewportWidth, style: model.style, metrics: metrics)
        guard let slot = layout.slot(Self.placeholderID) else { return nil }
        let offset = TabScrollMath.clamp(scroll.target, contentWidth: layout.contentWidth, viewportWidth: viewportWidth)
        let local = CGRect(
            x: slot.x - offset,
            y: metrics.stripVerticalPadding,
            width: slot.width,
            height: max(0, bounds.height - 2 * metrics.stripVerticalPadding)
        )
        let frameInWindow = tabsClip.convert(local, to: nil)
        return TabStripDropTarget(stripID: model.stripID, index: index, ghostFrame: window.convertToScreen(frameInWindow))
    }

    /// Opens (or moves) a spring-animated gap for an external drag at
    /// `screenPoint` and returns the target. Closes the gap and returns nil
    /// when the point is not over this strip. Call on every pointer move.
    @discardableResult
    public func updatePhantom(atScreenPoint screenPoint: CGPoint) -> TabStripDropTarget? {
        guard let target = dropTarget(atScreenPoint: screenPoint) else {
            hidePhantom()
            return nil
        }
        if let window { phantomPoint = convert(window.convertPoint(fromScreen: screenPoint), from: nil) }
        setHovered(nil)
        hoverCard.hide(allowsQuickReshow: false)
        if target.index != dropPlaceholderIndex {
            dropPlaceholderIndex = target.index
            relayout(animated: !reduceMotion)
        }
        return target
    }

    /// Closes the phantom gap with springs (the drag left or was cancelled).
    public func hidePhantom() {
        phantomPoint = nil
        guard dropPlaceholderIndex != nil, pendingDrop == nil else { return }
        dropPlaceholderIndex = nil
        relayout(animated: !reduceMotion)
    }

    /// Call when the session commits a drop on this strip, before or right
    /// after sending the move command. The arriving tab takes over the
    /// phantom's geometry instead of growing in, and a tab this strip handed
    /// off reappears at the drop index at once (optimistic reorder).
    public func commitPhantom(tabID: TabID) {
        phantomPoint = nil
        guard let index = dropPlaceholderIndex, let slot = result.slot(Self.placeholderID) else { return }
        pendingDrop = (tabID, slot.x, slot.width)
        if detachedID == tabID {
            detachedID = nil
            var ids = displayed.map(\.id)
            ids.insert(tabID, at: min(index, ids.count))
            orderOverride = ids
        }
        sync(fromModel: false)
    }

    private func phantomIndex(at point: CGPoint) -> Int {
        let base = TabLayoutEngine.layout(
            items: displayed.map { TabLayoutItem(id: $0.id, isPinned: $0.isPinned, isSelected: $0.id == model.selectedID) },
            availableWidth: viewportWidth,
            style: model.style,
            metrics: metrics
        )
        let pinnedCount = displayed.count(where: \.isPinned)
        let unpinned = base.slots.filter { !$0.isPinned }
        let groupStart = unpinned.first?.x ?? (base.contentWidth + (pinnedCount > 0 ? metrics.pinnedGroupGap : 0))
        let width = base.standardWidth > 0 ? base.standardWidth : metrics.maxTabWidth
        let contentX = convert(point, to: tabsClip).x + scroll.value
        return pinnedCount + TabReorderMath.insertionIndex(
            draggedMinX: contentX - width / 2,
            groupStart: groupStart,
            otherWidths: unpinned.map(\.width)
        )
    }
}

/// Everything the App's drag session needs when a tab leaves its strip.
public struct TabDragStart: Equatable, Sendable {
    public var tabID: TabID
    public var stripID: UUID
    /// Screen frame of the tab at hand-off.
    public var screenFrame: CGRect
    /// Pointer position inside the tab (screen orientation, bottom-left origin).
    public var grabOffset: CGPoint
    public var screenPoint: CGPoint
    /// Image of the tab itself. The session may prefer a content thumbnail.
    public var snapshot: TabImage?
}

/// Result of hit-testing a strip during an external drag.
public struct TabStripDropTarget: Equatable, Sendable {
    public var stripID: UUID
    /// Final index in `orderedTabs` (without a tab handed off from this strip).
    public var index: Int
    /// Screen frame of the inline slot for the ghost.
    public var ghostFrame: CGRect
}
