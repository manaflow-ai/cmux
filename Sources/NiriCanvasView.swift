#if DEBUG
import AppKit
import QuartzCore
import CoreText
import Bonsplit

// MARK: - Tab Bar

final class NiriTabBarView: NSView {

    struct Tab: Equatable { let id: UUID; var title: String }

    var tabs: [Tab] = [] { didSet { needsDisplay = true } }
    var selectedIndex: Int = 0 { didSet { needsDisplay = true } }
    var onSelect: ((Int) -> Void)?
    /// Called when user starts dragging a tab. Canvas takes over from here.
    var onDragStart: ((Int, NSEvent) -> Void)?

    static let height: CGFloat = 24
    private var hoveredIndex: Int? { didSet { if oldValue != hoveredIndex { needsDisplay = true } } }
    /// Set by canvas during drag to show drop indicator
    var dropIndicatorIndex: Int? { didSet { if oldValue != dropIndicatorIndex { needsDisplay = true } } }
    private var trackingArea: NSTrackingArea?
    private var mouseDownIdx: Int?
    private var mouseDownX: CGFloat = 0

    /// Background color for the bar (darkened terminal bg)
    var barBackgroundColor: CGColor = CGColor(gray: 0.15, alpha: 1) { didSet { needsDisplay = true } }
    /// Background color for the selected tab (terminal bg)
    var selectedTabColor: CGColor = CGColor(gray: 0.22, alpha: 1) { didSet { needsDisplay = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }
    override var mouseDownCanMoveWindow: Bool { false }
    override var isFlipped: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    private let maxTabW: CGFloat = 150
    private let minTabW: CGFloat = 40
    var tabScrollOffset: CGFloat = 0

    /// Width for a specific tab based on its content
    private func widthForTab(_ tab: Tab, index: Int) -> CGFloat {
        let title = tab.title.isEmpty ? "Shell" : String(tab.title.prefix(20))
        let titleW = measureText(title, fontSize: 11, fontName: ".AppleSystemUIFont")
        return min(maxTabW, max(minTabW, titleW + 20))  // 10px padding each side
    }

    /// Total width of all tabs
    private var totalTabsWidth: CGFloat {
        tabs.enumerated().reduce(0) { $0 + widthForTab($1.element, index: $1.offset) }
    }

    /// Whether tabs overflow the bar (need scrolling)
    var tabsOverflow: Bool { totalTabsWidth > bounds.width }

    /// X position of a tab's left edge (in scrollable content space)
    private func tabX(at index: Int) -> CGFloat {
        var x: CGFloat = 0
        for i in 0..<min(index, tabs.count) { x += widthForTab(tabs[i], index: i) }
        return x
    }

    /// Legacy: uniform tab width (used by some callers)
    var tabWidth: CGFloat {
        guard !tabs.isEmpty else { return 0 }
        return min(maxTabW, bounds.width / CGFloat(tabs.count))
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = trackingArea { removeTrackingArea(t) }
        trackingArea = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow], owner: self)
        addTrackingArea(trackingArea!)
    }

    override func mouseMoved(with event: NSEvent) {
        hoveredIndex = tabIndex(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) { hoveredIndex = nil }

    func tabIndex(at point: NSPoint) -> Int? {
        guard !tabs.isEmpty else { return nil }
        let x = point.x + tabScrollOffset
        var accum: CGFloat = 0
        for (i, tab) in tabs.enumerated() {
            let w = widthForTab(tab, index: i)
            if x >= accum && x < accum + w { return i }
            accum += w
        }
        return nil
    }

    func insertionIndex(at point: NSPoint) -> Int {
        let x = point.x + tabScrollOffset
        var accum: CGFloat = 0
        for (i, tab) in tabs.enumerated() {
            let w = widthForTab(tab, index: i)
            if x < accum + w / 2 { return i }
            accum += w
        }
        return tabs.count
    }

    // MARK: - Mouse: click-to-select + drag-start detection
    // On drag, the canvas takes over via onDragStart callback.

    override func mouseDown(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        mouseDownIdx = tabIndex(at: pt)
        mouseDownX = pt.x
    }

    override func mouseDragged(with event: NSEvent) {
        guard let idx = mouseDownIdx else { return }
        let pt = convert(event.locationInWindow, from: nil)
        if abs(pt.x - mouseDownX) > 5 {
            mouseDownIdx = nil  // hand off to canvas
            onDragStart?(idx, event)
        }
    }

    override func mouseUp(with event: NSEvent) {
        if let idx = mouseDownIdx {
            onSelect?(idx)
        }
        mouseDownIdx = nil
    }

    override func scrollWheel(with event: NSEvent) {
        if tabsOverflow {
            let delta = event.scrollingDeltaX != 0 ? event.scrollingDeltaX : event.scrollingDeltaY
            tabScrollOffset -= delta
            tabScrollOffset = max(0, min(totalTabsWidth - bounds.width, tabScrollOffset))
            needsDisplay = true
        }
        // Always consume — don't let scroll pass through to terminal
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        guard bounds.width > 1, bounds.height > 1 else { return }

        ctx.setFillColor(barBackgroundColor)
        ctx.fill(bounds)

        guard !tabs.isEmpty else { return }

        let hoverBg = CGColor(gray: 0.19, alpha: 1)
        let sep = CGColor(gray: 0.3, alpha: 0.5)

        // Ensure selected tab is scrolled into view
        if tabsOverflow {
            let selX = tabX(at: selectedIndex)
            let selW = widthForTab(tabs[selectedIndex], index: selectedIndex)
            if selX < tabScrollOffset { tabScrollOffset = selX }
            else if selX + selW > tabScrollOffset + bounds.width { tabScrollOffset = selX + selW - bounds.width }
            tabScrollOffset = max(0, min(totalTabsWidth - bounds.width, tabScrollOffset))
        } else {
            tabScrollOffset = 0
        }

        ctx.saveGState()
        ctx.clip(to: bounds)

        var xCursor: CGFloat = -tabScrollOffset
        for (i, tab) in tabs.enumerated() {
            let tw = widthForTab(tab, index: i)
            let x = xCursor

            // Skip if off-screen
            if x + tw < 0 || x > bounds.width { xCursor += tw; continue }

            if i == selectedIndex {
                ctx.setFillColor(selectedTabColor)
                ctx.fill(CGRect(x: x, y: 0, width: tw, height: bounds.height))
            } else if hoveredIndex == i && mouseDownIdx == nil {
                ctx.setFillColor(hoverBg)
                ctx.fill(CGRect(x: x, y: 0, width: tw, height: bounds.height))
            }

            if i > 0 {
                ctx.setFillColor(sep)
                ctx.fill(CGRect(x: x, y: 4, width: 1, height: bounds.height - 8))
            }

            let title = tab.title.isEmpty ? "Shell" : String(tab.title.prefix(20))
            let alpha: CGFloat = i == selectedIndex ? 0.9 : 0.5
            drawText(ctx: ctx, text: title, x: x + 10, centerY: bounds.height / 2,
                     fontSize: 11, fontName: ".AppleSystemUIFont", alpha: alpha)

            xCursor += tw
        }
        ctx.restoreGState()

        // No bottom border (removed)

        // Drop indicator (blue line)
        if let dropIdx = dropIndicatorIndex {
            let dropX = tabX(at: dropIdx) - tabScrollOffset
            ctx.setFillColor(CGColor(srgbRed: 0, green: 0.48, blue: 1, alpha: 1))
            ctx.fill(CGRect(x: dropX - 1.5, y: 4, width: 3, height: bounds.height - 8))
        }
    }

    private func drawText(ctx: CGContext, text: String, x: CGFloat, centerY: CGFloat,
                          fontSize: CGFloat, fontName: String, alpha: CGFloat) {
        let ctFont = CTFontCreateWithName(fontName as CFString, fontSize, nil)
        let attrs: [CFString: Any] = [kCTFontAttributeName: ctFont, kCTForegroundColorFromContextAttributeName: true]
        let attrStr = CFAttributedStringCreate(nil, text as CFString, attrs as CFDictionary)!
        let line = CTLineCreateWithAttributedString(attrStr)
        let r = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
        ctx.saveGState()
        ctx.setFillColor(CGColor(gray: 1.0, alpha: alpha))
        ctx.textPosition = CGPoint(x: x, y: centerY - r.height / 2 + 2)
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }

    private func measureText(_ text: String, fontSize: CGFloat, fontName: String) -> CGFloat {
        let ctFont = CTFontCreateWithName(fontName as CFString, fontSize, nil)
        let attrs: [CFString: Any] = [kCTFontAttributeName: ctFont]
        let attrStr = CFAttributedStringCreate(nil, text as CFString, attrs as CFDictionary)!
        let line = CTLineCreateWithAttributedString(attrStr)
        return CTLineGetBoundsWithOptions(line, .useOpticalBounds).width
    }

    /// Show a drop indicator at the given insertion index (called by NiriCanvasView during cross-panel drag)
    func showDropIndicator(at index: Int?) { dropIndicatorIndex = index }
}

// MARK: - Niri Canvas View

final class NiriCanvasView: NSView {

    struct Panel {
        var tabs: [TerminalSurface]
        var activeTab: Int = 0
        var closing: Bool = false
        var closeProgress: CGFloat = 1.0
        var presetIndex: Int = 1
        var currentWidth: CGFloat = 0.67
        var targetWidth: CGFloat = 0.67
        var tabBar: NiriTabBarView
        var containerView: NSView
        /// Tracks titles per surface ID (set via ghostty notification)
        var tabTitles: [UUID: String] = [:]
        /// ID of the panel this was split from (for instant close width absorption)
        var splitPartnerId: UUID?
        /// Width before the split that created this panel
        var preSplitWidth: CGFloat?
        /// Unique ID for this panel (for split partner tracking)
        let panelId: UUID = UUID()

        var activeSurface: TerminalSurface? {
            guard activeTab >= 0, activeTab < tabs.count else { return nil }
            return tabs[activeTab]
        }

        mutating func syncTabBar() {
            tabBar.tabs = tabs.map { s in
                let title = tabTitles[s.id] ?? "Shell"
                return NiriTabBarView.Tab(id: s.id, title: title)
            }
            tabBar.selectedIndex = activeTab
        }
    }

    private(set) var panels: [Panel] = []
    var focusedIndex: Int = 0
    private var scrollOffset: CGFloat = 0
    private var targetOffset: CGFloat = 0
    private var displayLink: CVDisplayLink?
    private var titleObserver: NSObjectProtocol?
    /// Track last known bounds width for resize detection in tick()
    private var lastBoundsWidth: CGFloat = 0

    /// Blue drop indicator between panels (index = insertion point, 0...panels.count)
    private var panelDropIndex: Int? { didSet { if oldValue != panelDropIndex { needsDisplay = true } } }

    private let panelGap: CGFloat = 12
    private let peekWidth: CGFloat = 20
    private let springK: CGFloat = 0.16
    let widthPresets: [CGFloat] = [0.33, 0.67, 1.0]

    override init(frame: NSRect) { super.init(frame: frame); setup() }
    required init?(coder: NSCoder) { super.init(coder: coder); setup() }

    private func setup() {
        wantsLayer = true
        layer!.backgroundColor = NSColor(red: 0.06, green: 0.06, blue: 0.08, alpha: 1).cgColor
        // Display link deferred to setSurfaces() to avoid constraint loops on empty canvas
    }

    deinit {
        if let displayLink { CVDisplayLinkStop(displayLink) }
        if let obs = titleObserver { NotificationCenter.default.removeObserver(obs) }
    }

    // MARK: - Logging

    private func nlog(_ msg: String) {
        let state = "focus=\(focusedIndex) live=\(liveCount) panels=\(panels.count)"
        dlog("niri: \(msg) [\(state)]")
    }

    // MARK: - Panel Management

    func setSurfaces(_ surfaces: [TerminalSurface]) {
        for p in panels { p.containerView.removeFromSuperview() }
        panels = surfaces.map { makePanel(with: [$0]) }
        for p in panels { addSubview(p.containerView) }
        focusedIndex = min(focusedIndex, max(0, liveCount - 1))
        targetOffset = stripX(forLive: focusedIndex)
        scrollOffset = targetOffset
        if displayLink == nil { startDisplayLink() }
        updateTabBarColors()
        layoutStrip()

        // Register title observer here (not in setup) to avoid crashes when
        // the main cmux window instantiates NiriCanvasView without panels.
        if titleObserver == nil {
            titleObserver = NotificationCenter.default.addObserver(
                forName: .ghosttyDidSetTitle,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let self = self else { return }
                guard let surfaceId = notification.userInfo?[GhosttyNotificationKey.surfaceId] as? UUID,
                      let title = notification.userInfo?[GhosttyNotificationKey.title] as? String else { return }
                self.handleTitleChange(surfaceId: surfaceId, title: title)
            }
        }
    }

    private func handleTitleChange(surfaceId: UUID, title: String) {
        // Extract last path component for cleaner display
        let displayTitle: String
        if title.hasPrefix("/") || title.contains("/") {
            displayTitle = (title as NSString).lastPathComponent
        } else {
            displayTitle = title
        }
        for i in 0..<panels.count {
            if panels[i].tabs.contains(where: { $0.id == surfaceId }) {
                panels[i].tabTitles[surfaceId] = displayTitle
                panels[i].syncTabBar()
            }
        }
    }

    /// Update tab bar colors from the ghostty theme
    private func updateTabBarColors() {
        let termBg = GhosttyApp.shared.defaultBackgroundColor
        let cgTermBg = termBg.cgColor
        // Bar bg = terminal bg darkened 15%
        let barBg: CGColor
        if let comps = cgTermBg.components, cgTermBg.numberOfComponents >= 3 {
            let factor: CGFloat = 0.85
            barBg = CGColor(srgbRed: comps[0] * factor, green: comps[1] * factor, blue: comps[2] * factor, alpha: 1)
        } else {
            barBg = CGColor(gray: 0.12, alpha: 1)
        }
        for p in panels {
            p.tabBar.barBackgroundColor = barBg
            p.tabBar.selectedTabColor = cgTermBg
        }
    }

    /// Container that prioritizes the tab bar for hit testing.
    private final class PanelContainerView: NSView {
        weak var tabBar: NiriTabBarView?
        override func hitTest(_ point: NSPoint) -> NSView? {
            // hitTest point is in superview's coordinate space.
            let localPt = convert(point, from: superview)
            if let tb = tabBar {
                // Check if the click is in the tab bar's frame (in our local coords)
                if localPt.y >= tb.frame.minY && localPt.y <= tb.frame.maxY
                    && localPt.x >= tb.frame.minX && localPt.x <= tb.frame.maxX {
                    NSLog("niri.hitTest -> TAB BAR local=\(localPt) tbFrame=\(tb.frame)")
                    return tb
                }
            }
            let result = super.hitTest(point)
            if localPt.y >= (frame.height - 40) {
                // Near the tab bar area but missed - log for debugging
                NSLog("niri.hitTest MISS near tabBar local=\(localPt) tbFrame=\(tabBar?.frame ?? .zero) result=\(type(of: result).self)")
            }
            return result
        }
    }

    /// Set to true to use plain colored views instead of ghostty terminals (for debugging hit test)
    var debugNoGhostty = false

    private func makePanel(with surfaces: [TerminalSurface]) -> Panel {
        let container = PanelContainerView()
        container.wantsLayer = true
        if debugNoGhostty {
            // Plain colored placeholder instead of ghostty terminal
            let placeholder = NSView()
            placeholder.wantsLayer = true
            placeholder.layer?.backgroundColor = CGColor(gray: 0.12, alpha: 1)
            container.addSubview(placeholder)
        } else if let active = surfaces.first {
            active.hostedView.removeFromSuperview()
            container.addSubview(active.hostedView)
        }
        let tabBar = NiriTabBarView(frame: .zero)
        container.addSubview(tabBar)
        container.tabBar = tabBar
        var panel = Panel(tabs: surfaces, activeTab: 0, tabBar: tabBar, containerView: container)
        panel.syncTabBar()

        let panelId = ObjectIdentifier(container)
        tabBar.onSelect = { [weak self] idx in self?.selectTab(idx, inPanel: panelId) }
        tabBar.onDragStart = { [weak self] idx, event in self?.beginTabDrag(tabIndex: idx, fromPanel: panelId, event: event) }
        return panel
    }

    private func panelIndex(for id: ObjectIdentifier) -> Int? {
        panels.firstIndex(where: { ObjectIdentifier($0.containerView) == id })
    }

    var liveCount: Int { panels.count(where: { !$0.closing }) }

    var liveIndices: [(panel: Int, live: Int)] {
        var r: [(Int, Int)] = []; var li = 0
        for (i, p) in panels.enumerated() where !p.closing { r.append((i, li)); li += 1 }
        return r
    }

    var focusedSurface: TerminalSurface? {
        let live = liveIndices
        guard focusedIndex >= 0, focusedIndex < live.count else { return nil }
        return panels[live[focusedIndex].panel].activeSurface
    }

    // MARK: - Tab Operations

    func selectTab(_ idx: Int, inPanel id: ObjectIdentifier) {
        nlog("selectTab idx=\(idx) panel=\(panelIndex(for: id) ?? -1)")
        guard let pi = panelIndex(for: id), idx < panels[pi].tabs.count else { return }
        // Focus this panel if it's not already focused
        let live = liveIndices
        if let li = live.first(where: { $0.panel == pi })?.live, li != focusedIndex {
            focusedIndex = li
            scrollToReveal()
        }
        panels[pi].activeSurface?.hostedView.removeFromSuperview()
        panels[pi].activeTab = idx
        panels[pi].syncTabBar()
        if let s = panels[pi].activeSurface {
            s.hostedView.removeFromSuperview()
            panels[pi].containerView.addSubview(s.hostedView)
        }
        layoutStrip(); focusCurrentTerminal()
    }

    func reorderTab(from: Int, to: Int, inPanel id: ObjectIdentifier) {
        nlog("reorderTab from=\(from) to=\(to) panel=\(panelIndex(for: id) ?? -1)")
        guard let pi = panelIndex(for: id) else { return }
        guard from < panels[pi].tabs.count, to < panels[pi].tabs.count, from != to else { return }
        let tab = panels[pi].tabs.remove(at: from)
        panels[pi].tabs.insert(tab, at: to)
        if panels[pi].activeTab == from { panels[pi].activeTab = to }
        else if from < panels[pi].activeTab && to >= panels[pi].activeTab { panels[pi].activeTab -= 1 }
        else if from > panels[pi].activeTab && to <= panels[pi].activeTab { panels[pi].activeTab += 1 }
        panels[pi].syncTabBar()
    }

    // MARK: - Tab Drag (canvas-level, cross-panel)

    private var dragLayer: CALayer?
    private var currentDropTarget: DropTarget?
    private var isDragging = false
    private var dragMousePt: NSPoint = .zero
    private var dragScrollDwell: CGFloat = 0  // seconds in the scroll zone
    private var dragSrcPi: Int = 0
    private var dragSrcTab: Int = 0
    private var dragSrcTabCount: Int = 0
    var suppressHitTestFocus = false

    enum DropEdge: Equatable { case left, right, top, bottom }

    struct DropTarget {
        enum Kind: Equatable {
            case inTabBar(livePanel: Int, insertionIndex: Int)
            case betweenPanels(insertionIndex: Int)
            case terminalEdge(livePanel: Int, edge: DropEdge)
            case terminalCenter(livePanel: Int)
        }
        let kind: Kind
    }

    private var dropZoneLayer: CALayer?

    private func beginTabDrag(tabIndex: Int, fromPanel panelId: ObjectIdentifier, event: NSEvent) {
        nlog("beginTabDrag tab=\(tabIndex) panel=\(panelIndex(for: panelId) ?? -1)")
        guard let srcPi = panelIndex(for: panelId) else { return }
        let srcTabCount = panels[srcPi].tabs.count

        // Create floating drag layer with tab title
        let title = panels[srcPi].tabBar.tabs.indices.contains(tabIndex)
            ? (panels[srcPi].tabBar.tabs[tabIndex].title.isEmpty ? "Shell" : panels[srcPi].tabBar.tabs[tabIndex].title)
            : "Shell"
        let dl = CATextLayer()
        dl.string = title
        dl.font = CTFontCreateWithName("Helvetica Neue" as CFString, 11, nil)
        dl.fontSize = 11
        dl.foregroundColor = CGColor(gray: 1, alpha: 0.9)
        dl.alignmentMode = .center
        dl.truncationMode = .end
        dl.frame = CGRect(x: 0, y: 0, width: 100, height: NiriTabBarView.height)
        dl.backgroundColor = CGColor(gray: 0.22, alpha: 0.95)
        dl.cornerRadius = 6
        dl.borderColor = CGColor(srgbRed: 0, green: 0.48, blue: 1, alpha: 0.8)
        dl.borderWidth = 1.5
        dl.shadowColor = CGColor(gray: 0, alpha: 1)
        dl.shadowOpacity = 0.5
        dl.shadowRadius = 8
        dl.contentsScale = window?.backingScaleFactor ?? 2
        dl.zPosition = 1000
        dl.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        layer?.addSublayer(dl)
        dragLayer = dl

        let mousePt = convert(event.locationInWindow, from: nil)
        dl.position = CGPoint(x: mousePt.x, y: mousePt.y)
        isDragging = true
        dragMousePt = mousePt
        dragScrollDwell = 0
        dragSrcPi = srcPi
        dragSrcTab = tabIndex
        dragSrcTabCount = srcTabCount
        suppressHitTestFocus = true

        // Tracking loop: mouse events + keyboard (Escape to cancel)
        var cancelled = false
        while let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp, .keyDown]) {
            if next.type == .keyDown && next.keyCode == 53 { cancelled = true; break }
            let pt = convert(next.locationInWindow, from: nil)
            dragMousePt = pt  // update for tick() to use

            if next.type == .leftMouseUp {
                if !cancelled {
                    completeDrag(sourcePi: srcPi, sourceTab: tabIndex)
                }
                break
            }

            // Move drag layer
            CATransaction.begin(); CATransaction.setDisableActions(true)
            dl.position = CGPoint(x: pt.x, y: pt.y)
            CATransaction.commit()

            // Update drop target
            updateDropTarget(at: pt, srcPi: srcPi, srcTab: tabIndex, srcTabCount: srcTabCount)
        }

        // Clean up
        cleanupDrag()
    }

    private func updateDropTarget(at pt: NSPoint, srcPi: Int, srcTab: Int, srcTabCount: Int) {
        for p in panels { p.tabBar.dropIndicatorIndex = nil }
        panelDropIndex = nil
        currentDropTarget = nil
        hideDropZoneOverlay()

        let live = liveIndices
        let isSingleTab = srcTabCount <= 1

        // 1. Check tab bars
        for (li, entry) in live.enumerated() {
            let p = panels[entry.panel]
            let cf = p.containerView.frame
            // Extended hit area above and below the tab bar
            let hitRect = CGRect(x: cf.minX, y: cf.minY + cf.height - NiriTabBarView.height - 10,
                                 width: cf.width, height: NiriTabBarView.height + 30)
            guard hitRect.contains(pt) else { continue }

            let localX = pt.x - cf.minX
            let insertIdx = p.tabBar.insertionIndex(at: NSPoint(x: localX, y: 0))
            let isSamePanel = entry.panel == srcPi

            // Skip: same position in same panel
            if isSamePanel && (insertIdx == srcTab || insertIdx == srcTab + 1) { return }

            p.tabBar.dropIndicatorIndex = insertIdx
            currentDropTarget = .init(kind: .inTabBar(livePanel: li, insertionIndex: insertIdx))
            return
        }

        // 2. Check gaps between panels
        for li in 0...live.count {
            // Skip gaps adjacent to source panel if it only has 1 tab
            // (dragging the only tab to the gap next to its own panel is a no-op)
            if isSingleTab {
                let srcLive = live.first(where: { $0.panel == srcPi })?.live
                if let sl = srcLive {
                    if li == sl || li == sl + 1 { continue }
                }
            }

            let gapX = gapScreenX(atLive: li, live: live)
            if abs(pt.x - gapX) < 25 {
                panelDropIndex = li
                currentDropTarget = .init(kind: .betweenPanels(insertionIndex: li))
                hideDropZoneOverlay()
                needsDisplay = true
                return
            }
        }

        // 3. Check terminal areas for edge/center drop zones
        for (li, entry) in live.enumerated() {
            let p = panels[entry.panel]
            let cf = p.containerView.frame
            guard cf.contains(pt) else { continue }

            // Terminal area (below tab bar)
            let termRect = CGRect(x: cf.minX, y: cf.minY,
                                  width: cf.width, height: cf.height - NiriTabBarView.height)
            guard termRect.contains(pt) else { continue }

            let localX = (pt.x - termRect.minX) / termRect.width
            let localY = (pt.y - termRect.minY) / termRect.height
            let edgeRatio: CGFloat = 0.25
            // Larger drop zone on outer edges (first panel left, last panel right)
            let isFirstPanel = li == 0
            let isLastPanel = li == live.count - 1
            let leftRatio: CGFloat = isFirstPanel ? 0.4 : edgeRatio
            let rightRatio: CGFloat = isLastPanel ? 0.4 : edgeRatio

            let edge: DropEdge?
            if localX < leftRatio { edge = .left }
            else if localX > 1 - rightRatio { edge = .right }
            else if localY > 1 - edgeRatio { edge = .top }
            else if localY < edgeRatio { edge = .bottom }
            else { edge = nil }

            let isSamePanel = entry.panel == srcPi

            if let edge {
                // Skip edge drops on own panel with single tab (would just recreate same layout)
                if isSamePanel && isSingleTab && (edge == .left || edge == .right) { return }
                currentDropTarget = .init(kind: .terminalEdge(livePanel: li, edge: edge))
                showDropZoneOverlay(in: termRect, edge: edge)
            } else {
                // Skip center drop on own panel (no-op: tab is already there)
                if isSamePanel { return }
                currentDropTarget = .init(kind: .terminalCenter(livePanel: li))
                showDropZoneOverlay(in: termRect, edge: nil)
            }
            return
        }

        hideDropZoneOverlay()
    }

    private func showDropZoneOverlay(in rect: CGRect, edge: DropEdge?) {
        if dropZoneLayer == nil {
            let l = CALayer()
            l.zPosition = 500
            layer?.addSublayer(l)
            dropZoneLayer = l
        }
        guard let l = dropZoneLayer else { return }

        let pad: CGFloat = 4
        let targetRect: CGRect
        if let edge {
            switch edge {
            case .left:   targetRect = CGRect(x: rect.minX + pad, y: rect.minY + pad, width: rect.width * 0.5 - pad * 2, height: rect.height - pad * 2)
            case .right:  targetRect = CGRect(x: rect.midX + pad, y: rect.minY + pad, width: rect.width * 0.5 - pad * 2, height: rect.height - pad * 2)
            case .top:    targetRect = CGRect(x: rect.minX + pad, y: rect.midY + pad, width: rect.width - pad * 2, height: rect.height * 0.5 - pad * 2)
            case .bottom: targetRect = CGRect(x: rect.minX + pad, y: rect.minY + pad, width: rect.width - pad * 2, height: rect.height * 0.5 - pad * 2)
            }
        } else {
            targetRect = rect.insetBy(dx: pad, dy: pad)
        }

        CATransaction.begin(); CATransaction.setDisableActions(true)
        l.frame = targetRect
        l.backgroundColor = CGColor(srgbRed: 0, green: 0.48, blue: 1, alpha: 0.15)
        l.borderColor = CGColor(srgbRed: 0, green: 0.48, blue: 1, alpha: 0.6)
        l.borderWidth = 2
        l.cornerRadius = 4
        l.isHidden = false
        CATransaction.commit()
    }

    private func hideDropZoneOverlay() {
        dropZoneLayer?.isHidden = true
    }

    private func gapScreenX(atLive li: Int, live: [(panel: Int, live: Int)]) -> CGFloat {
        if li <= 0 {
            return peekWidth + panelGap + (stripX(forLive: 0) - scrollOffset) - panelGap / 2
        } else if li >= live.count {
            let lastStart = stripX(forLive: live.count - 1)
            let lastW = pw(for: panels[live[live.count - 1].panel])
            return peekWidth + panelGap + (lastStart + lastW - scrollOffset) + panelGap / 2
        } else {
            return peekWidth + panelGap + (stripX(forLive: li) - scrollOffset) - panelGap / 2
        }
    }

    private func completeDrag(sourcePi: Int, sourceTab: Int) {
        nlog("completeDrag srcPanel=\(sourcePi) srcTab=\(sourceTab) target=\(currentDropTarget.map { String(describing: $0.kind) } ?? "nil")")
        guard let target = currentDropTarget else { return }

        // Capture scroll position before drop to stabilize viewport
        let scrollBefore = scrollOffset

        switch target.kind {
        case .inTabBar(let targetLive, let insertIdx):
            let live = liveIndices
            guard targetLive < live.count else { break }
            let targetPi = live[targetLive].panel

            if targetPi == sourcePi {
                reorderTab(from: sourceTab,
                           to: min(insertIdx, panels[sourcePi].tabs.count - 1),
                           inPanel: ObjectIdentifier(panels[sourcePi].containerView))
            } else {
                moveTab(fromPanel: sourcePi, tabIndex: sourceTab, toPanel: targetPi, insertAt: insertIdx)
            }
            // Recompute focused index: find the destination panel's current live index
            // (may have shifted if source panel was closed)
            let newLive = liveIndices
            focusedIndex = newLive.first(where: { $0.panel == targetPi })?.live ?? min(targetLive, liveCount - 1)

        case .betweenPanels(let insertLive):
            moveTabToNewPanel(fromPanel: sourcePi, tabIndex: sourceTab, atLiveIndex: insertLive)

        case .terminalCenter(let targetLive):
            // Add as tab in the target panel
            let live = liveIndices
            guard targetLive < live.count else { break }
            let targetPi = live[targetLive].panel
            moveTab(fromPanel: sourcePi, tabIndex: sourceTab, toPanel: targetPi, insertAt: panels[targetPi].tabs.count)
            let newLive = liveIndices
            focusedIndex = newLive.first(where: { $0.panel == targetPi })?.live ?? min(targetLive, liveCount - 1)

        case .terminalEdge(let targetLive, let edge):
            let live = liveIndices
            guard targetLive < live.count else { break }
            let targetPi = live[targetLive].panel
            guard sourceTab < panels[sourcePi].tabs.count else { break }
            let surface = panels[sourcePi].tabs[sourceTab]
            // Capture source width before removal
            let sourceWidth = panels[sourcePi].targetWidth
            // Remove from source
            panels[sourcePi].activeSurface?.hostedView.removeFromSuperview()
            panels[sourcePi].tabs.remove(at: sourceTab)
            if panels[sourcePi].tabs.isEmpty {
                panels[sourcePi].containerView.removeFromSuperview()
                panels.remove(at: sourcePi)
            } else {
                panels[sourcePi].activeTab = min(panels[sourcePi].activeTab, panels[sourcePi].tabs.count - 1)
                panels[sourcePi].syncTabBar()
                if let s = panels[sourcePi].activeSurface {
                    s.hostedView.removeFromSuperview()
                    panels[sourcePi].containerView.addSubview(s.hostedView)
                }
            }

            // New column inherits the SOURCE panel's width (not half the target)
            let newLive2 = liveIndices
            var newCol = makePanel(with: [surface])
            newCol.targetWidth = sourceWidth
            newCol.currentWidth = sourceWidth
            newCol.presetIndex = -1

            switch edge {
            case .left:
                let insertPi = newLive2.first(where: { $0.live == targetLive })?.panel ?? targetPi
                panels.insert(newCol, at: insertPi)
                addSubview(newCol.containerView)
            case .right:
                let insertPi = (newLive2.first(where: { $0.live == targetLive })?.panel ?? targetPi) + 1
                panels.insert(newCol, at: min(insertPi, panels.count))
                addSubview(newCol.containerView)
            case .top, .bottom:
                let insertPi = (newLive2.first(where: { $0.live == targetLive })?.panel ?? targetPi) + 1
                panels.insert(newCol, at: min(insertPi, panels.count))
                addSubview(newCol.containerView)
            }
            let finalLive = liveIndices
            focusedIndex = min(focusedIndex, max(0, finalLive.count - 1))
        }

        layoutStrip()
        // Keep viewport stable: don't scroll unless the focused panel is off-screen
        scrollOffset = scrollBefore
        targetOffset = scrollBefore
        scrollToReveal()
        focusCurrentTerminal()
    }

    private func cleanupDrag() {
        isDragging = false
        dragLayer?.removeFromSuperlayer()
        dragLayer = nil
        dropZoneLayer?.removeFromSuperlayer()
        dropZoneLayer = nil
        for p in panels { p.tabBar.dropIndicatorIndex = nil }
        panelDropIndex = nil
        currentDropTarget = nil
        needsDisplay = true
        // Delay clearing the suppress flag so the post-drag hitTest doesn't steal focus
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.suppressHitTestFocus = false
        }
    }

    private func moveTab(fromPanel srcPi: Int, tabIndex srcTab: Int, toPanel dstPi: Int, insertAt dstTab: Int) {
        nlog("moveTab src=\(srcPi):\(srcTab) dst=\(dstPi):\(dstTab)")
        guard srcTab < panels[srcPi].tabs.count else { return }
        let surface = panels[srcPi].tabs[srcTab]

        // Remove from source
        panels[srcPi].activeSurface?.hostedView.removeFromSuperview()
        panels[srcPi].tabs.remove(at: srcTab)
        if panels[srcPi].tabs.isEmpty {
            panels[srcPi].closing = true
        } else {
            panels[srcPi].activeTab = min(panels[srcPi].activeTab, panels[srcPi].tabs.count - 1)
            panels[srcPi].syncTabBar()
            // Show new active in source
            if let s = panels[srcPi].activeSurface {
                s.hostedView.removeFromSuperview()
                panels[srcPi].containerView.addSubview(s.hostedView)
            }
        }

        // Remove old active from destination before inserting
        panels[dstPi].activeSurface?.hostedView.removeFromSuperview()

        let clampedDst = min(dstTab, panels[dstPi].tabs.count)
        panels[dstPi].tabs.insert(surface, at: clampedDst)
        panels[dstPi].activeTab = clampedDst
        panels[dstPi].syncTabBar()

        // Show the new active surface in destination
        if let s = panels[dstPi].activeSurface {
            s.hostedView.removeFromSuperview()
            panels[dstPi].containerView.addSubview(s.hostedView)
        }
    }

    private func moveTabToNewPanel(fromPanel srcPi: Int, tabIndex srcTab: Int, atLiveIndex insertLive: Int) {
        nlog("moveTabToNewPanel src=\(srcPi):\(srcTab) insertLive=\(insertLive)")
        guard srcTab < panels[srcPi].tabs.count else { return }
        let surface = panels[srcPi].tabs[srcTab]

        // Remove from source
        panels[srcPi].activeSurface?.hostedView.removeFromSuperview()
        panels[srcPi].tabs.remove(at: srcTab)
        if panels[srcPi].tabs.isEmpty {
            panels[srcPi].closing = true
        } else {
            panels[srcPi].activeTab = min(panels[srcPi].activeTab, panels[srcPi].tabs.count - 1)
            panels[srcPi].syncTabBar()
            if let s = panels[srcPi].activeSurface {
                s.hostedView.removeFromSuperview()
                panels[srcPi].containerView.addSubview(s.hostedView)
            }
        }

        // New panel inherits the source panel's width preset
        var newPanel = makePanel(with: [surface])
        newPanel.presetIndex = panels[srcPi].presetIndex
        newPanel.currentWidth = panels[srcPi].currentWidth
        newPanel.targetWidth = panels[srcPi].targetWidth

        let live = liveIndices
        let insertAt = insertLive < live.count ? live[insertLive].panel : panels.count
        panels.insert(newPanel, at: insertAt)
        addSubview(newPanel.containerView)
        // Find the new panel's live index after insertion
        let newLive = liveIndices
        let newPanelId = ObjectIdentifier(newPanel.containerView)
        focusedIndex = newLive.first(where: { ObjectIdentifier(panels[$0.panel].containerView) == newPanelId })?.live
            ?? min(insertLive, liveCount - 1)
        nlog("moveTabToNewPanel done newFocus=\(focusedIndex)")
    }

    // MARK: - Geometry

    private var maxW: CGFloat { bounds.width - peekWidth * 2 - panelGap * 2 - panelGap }
    func pw(for p: Panel) -> CGFloat { max(300, (maxW - panelGap) * p.currentWidth) }

    /// Returns the live panel index whose container frame contains the given point (in canvas coords).
    func liveIndexAtPoint(_ pt: NSPoint) -> Int? {
        let live = liveIndices
        for (li, entry) in live.enumerated() {
            let cf = panels[entry.panel].containerView.frame
            if pt.x >= cf.minX && pt.x <= cf.maxX { return li }
        }
        return nil
    }

    func stripX(forLive target: Int) -> CGFloat {
        var x: CGFloat = 0; var li = 0
        for p in panels {
            if p.closing { x += pw(for: p) * p.closeProgress + panelGap * p.closeProgress; continue }
            if li == target { return x }
            x += pw(for: p) + panelGap; li += 1
        }
        return x
    }

    // MARK: - Layout

    private func layoutStrip() {
        let viewH = bounds.height
        let tabH = NiriTabBarView.height
        let ph = max(300, viewH - 4)
        let termH = ph - tabH
        let topY = (viewH - ph) / 2
        var xCursor: CGFloat = 0; var li = 0

        for i in 0..<panels.count {
            let p = panels[i]
            let progress = p.closing ? p.closeProgress : 1.0
            let w = pw(for: p) * progress
            let gap = panelGap * progress
            let screenX = peekWidth + panelGap + (xCursor - scrollOffset)
            let isFocused = !p.closing && li == focusedIndex

            p.containerView.frame = CGRect(x: screenX, y: topY, width: max(0, w), height: ph)
            p.containerView.alphaValue = p.closing ? max(0, progress) : 1.0
            p.tabBar.frame = CGRect(x: 0, y: ph - tabH, width: max(0, w), height: tabH)
            p.tabBar.needsDisplay = true
            if debugNoGhostty {
                // Size the placeholder view
                if let placeholder = p.containerView.subviews.first(where: { !($0 is NiriTabBarView) }) {
                    placeholder.frame = CGRect(x: 0, y: 0, width: max(0, w), height: termH)
                }
            } else {
                p.activeSurface?.hostedView.frame = CGRect(x: 0, y: 0, width: max(0, w), height: termH)
            }

            if let l = p.containerView.layer {
                l.cornerRadius = 0; l.masksToBounds = true
                l.borderWidth = isFocused ? 2 : 1
                l.borderColor = isFocused
                    ? CGColor(srgbRed: 0.0, green: 0.48, blue: 1.0, alpha: 0.7)
                    : CGColor(gray: 0.3, alpha: 1)
            }
            xCursor += w + gap
            if !p.closing { li += 1 }
        }
    }

    // Top-level hitTest: check ALL tab bars first before anything else.
    // This bypasses the entire subview hitTest chain so ghostty views can't steal the hit.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let localPt = convert(point, from: superview)
        let live = liveIndices
        for (li, entry) in live.enumerated() {
            let p = panels[entry.panel]
            let cf = p.containerView.frame
            guard cf.contains(localPt) else { continue }

            // Tab bar region: route to tab bar
            let tabBarFrame = CGRect(x: cf.minX, y: cf.minY + cf.height - NiriTabBarView.height,
                                     width: cf.width, height: NiriTabBarView.height)
            if tabBarFrame.contains(localPt) { return p.tabBar }

            // Terminal region: let the click through to ghostty
            // Focus is handled in NiriCanvasWindow.sendEvent, not here.
            return super.hitTest(point)
        }
        return super.hitTest(point)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        // Draw panel drop indicator (blue line between panels)
        guard let dropIdx = panelDropIndex, let ctx = NSGraphicsContext.current?.cgContext else { return }
        let live = liveIndices
        guard !live.isEmpty else { return }

        let ph = max(300, bounds.height - 4)
        let topY = (bounds.height - ph) / 2

        // Compute the X position for the drop indicator
        let dropX: CGFloat
        if dropIdx <= 0 {
            dropX = peekWidth + panelGap + (stripX(forLive: 0) - scrollOffset) - panelGap / 2
        } else if dropIdx >= liveCount {
            let lastStart = stripX(forLive: liveCount - 1)
            let lastW = pw(for: panels[live[liveCount - 1].panel])
            dropX = peekWidth + panelGap + (lastStart + lastW - scrollOffset) + panelGap / 2
        } else {
            let nextStart = stripX(forLive: dropIdx)
            dropX = peekWidth + panelGap + (nextStart - scrollOffset) - panelGap / 2
        }

        ctx.setFillColor(CGColor(srgbRed: 0.0, green: 0.48, blue: 1.0, alpha: 1.0))
        ctx.fill(CGRect(x: dropX - 1.5, y: topY + 10, width: 3, height: ph - 20))
    }

    // MARK: - Keys

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let f = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let cmd = f.contains(.command), opt = f.contains(.option), ctrl = f.contains(.control)
        let shift = f.contains(.shift)
        let ch = event.charactersIgnoringModifiers?.lowercased() ?? ""

        if cmd && opt {
            if event.keyCode == 123 { navigateLeft(); return true }
            if event.keyCode == 124 { navigateRight(); return true }
        }
        if cmd && ctrl {
            if ch == "h" { navigateLeft(); return true }
            if ch == "l" { navigateRight(); return true }
            if ch == "r" { cycleResize(); return true }
        }
        if ctrl && !cmd && !opt {
            if ch == "9" { switchToLastTab(); return true }
            if let n = Int(ch), n >= 1, n <= 8 { switchToTab(n - 1); return true }
        }
        if cmd && !ctrl && !opt && !shift && ch == "d" { splitRight(); return true }
        if cmd && !ctrl && !opt && !shift && ch == "w" { closeActiveTab(); return true }
        if cmd && !ctrl && !opt && !shift && ch == "t" { addNewTab(); return true }
        if cmd && !ctrl && !opt && !shift && ch == "n" { addNewPanel(); return true }
        return super.performKeyEquivalent(with: event)
    }

    func handleCtrlD() { closeActiveTab() }

    // MARK: - Panel Navigation

    func navigateLeft() {
        nlog("navigateLeft")
        guard focusedIndex > 0 else { return }
        focusedIndex -= 1; scrollToReveal(); focusCurrentTerminal()
    }

    func navigateRight() {
        nlog("navigateRight")
        guard focusedIndex < liveCount - 1 else { return }
        focusedIndex += 1; scrollToReveal(); focusCurrentTerminal()
    }

    func scrollToReveal() {
        let live = liveIndices
        guard focusedIndex < live.count else { return }
        ensureVisible(panelStart: stripX(forLive: focusedIndex), panelWidth: pw(for: panels[live[focusedIndex].panel]))
    }

    private func scrollToRevealTarget() {
        let live = liveIndices
        guard focusedIndex < live.count else { return }
        let p = panels[live[focusedIndex].panel]
        ensureVisible(panelStart: stripX(forLive: focusedIndex), panelWidth: max(300, maxW * p.targetWidth))
    }

    private func ensureVisible(panelStart: CGFloat, panelWidth w: CGFloat) {
        let vp = maxW
        let peek: CGFloat = 100 // extra peek when scrolling to reveal
        if w >= vp { targetOffset = panelStart }
        else {
            // Use 99% visibility threshold (fractional) instead of pixel tolerance.
            // Check against scrollOffset (current position) not targetOffset.
            let visibleLeft = max(panelStart, scrollOffset)
            let visibleRight = min(panelStart + w, scrollOffset + vp)
            let visibleAmount = max(0, visibleRight - visibleLeft)
            let fraction = w > 0 ? visibleAmount / w : 1.0
            if fraction < 0.99 {
                // Not fully visible, scroll to show it with peek
                let minO = panelStart + w - vp + peek
                let maxO = panelStart - peek
                if scrollOffset > maxO { targetOffset = max(0, maxO) }
                else if scrollOffset < minO { targetOffset = minO }
                else { targetOffset = scrollOffset }
            }
        }
        targetOffset = max(0, targetOffset)
    }

    // MARK: - Tab Navigation

    func switchToTabPublic(_ idx: Int) { switchToTab(idx) }
    func switchToLastTabPublic() { switchToLastTab() }

    private func switchToTab(_ idx: Int) {
        let live = liveIndices
        guard focusedIndex < live.count else { return }
        let pi = live[focusedIndex].panel
        guard idx < panels[pi].tabs.count else { return }
        selectTab(idx, inPanel: ObjectIdentifier(panels[pi].containerView))
    }

    private func switchToLastTab() {
        let live = liveIndices
        guard focusedIndex < live.count else { return }
        let pi = live[focusedIndex].panel
        guard !panels[pi].tabs.isEmpty else { return }
        selectTab(panels[pi].tabs.count - 1, inPanel: ObjectIdentifier(panels[pi].containerView))
    }

    func cycleTab(reverse: Bool) {
        let live = liveIndices
        guard focusedIndex < live.count else { return }
        let pi = live[focusedIndex].panel
        let count = panels[pi].tabs.count
        guard count > 1 else { return }
        let cur = panels[pi].activeTab
        let next = reverse ? (cur - 1 + count) % count : (cur + 1) % count
        selectTab(next, inPanel: ObjectIdentifier(panels[pi].containerView))
    }

    // MARK: - Resize

    func cycleResize() {
        nlog("cycleResize")
        let live = liveIndices
        guard focusedIndex < live.count else { return }
        let pi = live[focusedIndex].panel
        panels[pi].presetIndex = (panels[pi].presetIndex + 1) % widthPresets.count
        panels[pi].targetWidth = widthPresets[panels[pi].presetIndex]
        scrollToRevealTarget()
    }

    // MARK: - Split

    func splitRight() {
        nlog("splitRight")
        let live = liveIndices
        guard focusedIndex < live.count else { return }
        let ci = live[focusedIndex].panel
        guard GhosttyApp.shared.app != nil else { return }

        let originalWidth = panels[ci].targetWidth
        let originalPx = pw(for: panels[ci])
        let halfPx = (originalPx - panelGap) / 2.0
        let halfWidth = halfPx / (maxW - panelGap)

        let verifyPx = max(300, (maxW - panelGap) * halfWidth)
        nlog("splitRight originalW=\(String(format:"%.4f",originalWidth)) originalPx=\(String(format:"%.1f",originalPx)) halfPx=\(String(format:"%.1f",halfPx)) halfW=\(String(format:"%.4f",halfWidth)) verifyPx=\(String(format:"%.1f",verifyPx)) gap=\(panelGap) maxW=\(String(format:"%.1f",maxW)) total=\(String(format:"%.1f", verifyPx * 2 + panelGap))")

        // Track split partnership for instant close width absorption
        let originalPanelId = panels[ci].panelId
        panels[ci].preSplitWidth = originalWidth
        panels[ci].targetWidth = halfWidth
        panels[ci].currentWidth = halfWidth
        panels[ci].presetIndex = -1

        let surface = TerminalSurface(tabId: UUID(), context: GHOSTTY_SURFACE_CONTEXT_SPLIT, configTemplate: nil)
        var newCol = makePanel(with: [surface])
        newCol.targetWidth = halfWidth
        newCol.currentWidth = halfWidth
        newCol.presetIndex = -1
        newCol.splitPartnerId = originalPanelId
        newCol.preSplitWidth = originalWidth

        // Also set the original panel's partner to the new panel
        panels[ci].splitPartnerId = newCol.panelId

        panels.insert(newCol, at: ci + 1)
        addSubview(newCol.containerView)
        updateTabBarColors()
        focusedIndex += 1
        layoutStrip()
        logPanelPositions("after splitRight")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.focusCurrentTerminal() }
    }

    private func logPanelPositions(_ context: String) {
        let live = liveIndices
        var parts: [String] = []
        for (li, entry) in live.enumerated() {
            let p = panels[entry.panel]
            let x = p.containerView.frame.minX
            let w = p.containerView.frame.width
            parts.append("\(li):x=\(String(format:"%.1f",x)) w=\(String(format:"%.1f",w))")
        }
        nlog("positions [\(context)] scroll=\(String(format:"%.1f",scrollOffset)) \(parts.joined(separator: " | "))")
    }

    // MARK: - Close / Add

    func closeActiveTab() {
        nlog("closeActiveTab")
        let live = liveIndices
        guard !live.isEmpty, focusedIndex < live.count else { return }
        let pi = live[focusedIndex].panel
        if panels[pi].tabs.count <= 1 {
            // Close the entire column instantly (no animation)
            let closingPanelId = panels[pi].panelId
            let closingWidth = panels[pi].currentWidth
            if let s = panels[pi].activeSurface?.surface { ghostty_surface_request_close(s) }
            panels[pi].containerView.removeFromSuperview()
            panels.remove(at: pi)

            // Absorb width into split partner if one exists
            absorbWidthIntoPartner(closingPanelId: closingPanelId, closingWidth: closingWidth)

            if liveCount == 0 { window?.close(); return }

            // Focus neighbor with least scroll cost
            let newLive = liveIndices
            if !newLive.isEmpty {
                let best = leastScrollCostNeighbor(near: focusedIndex)
                focusedIndex = best
            } else {
                focusedIndex = 0
            }
            layoutStrip()
            logPanelPositions("after close-column")
            scrollToReveal()
            focusCurrentTerminal()
        } else {
            let idx = panels[pi].activeTab
            let surface = panels[pi].tabs[idx]
            surface.hostedView.removeFromSuperview()
            if let s = surface.surface { ghostty_surface_request_close(s) }
            panels[pi].tabs.remove(at: idx)
            panels[pi].activeTab = min(idx, panels[pi].tabs.count - 1)
            panels[pi].syncTabBar()
            if let a = panels[pi].activeSurface {
                a.hostedView.removeFromSuperview()
                panels[pi].containerView.addSubview(a.hostedView)
            }
            layoutStrip(); scrollToReveal(); focusCurrentTerminal()
        }
    }

    /// Absorb width from a closing panel back into its split partner
    private func absorbWidthIntoPartner(closingPanelId: UUID, closingWidth: CGFloat) {
        for i in 0..<panels.count {
            if panels[i].splitPartnerId == closingPanelId, let preW = panels[i].preSplitWidth {
                panels[i].targetWidth = preW
                panels[i].currentWidth = preW
                panels[i].splitPartnerId = nil
                panels[i].preSplitWidth = nil
                return
            }
        }
    }

    /// Find the live neighbor with least scroll cost
    private func leastScrollCostNeighbor(near oldFocus: Int) -> Int {
        let count = liveCount
        guard count > 0 else { return 0 }
        let clamped = min(oldFocus, count - 1)
        // Prefer the same index (right neighbor) or left neighbor
        let candidates = [clamped, max(0, clamped - 1)]
        var best = clamped
        var bestCost = CGFloat.infinity
        for c in candidates where c < count {
            let ps = stripX(forLive: c)
            let cost = abs(ps - scrollOffset)
            if cost < bestCost { bestCost = cost; best = c }
        }
        return best
    }

    func addNewTab() {
        nlog("addNewTab")
        guard GhosttyApp.shared.app != nil else { return }
        let live = liveIndices
        guard focusedIndex < live.count else { addNewPanel(); return }
        let pi = live[focusedIndex].panel
        let surface = TerminalSurface(tabId: UUID(), context: GHOSTTY_SURFACE_CONTEXT_SPLIT, configTemplate: nil)
        panels[pi].activeSurface?.hostedView.removeFromSuperview()
        let idx = panels[pi].activeTab + 1
        panels[pi].tabs.insert(surface, at: idx)
        panels[pi].activeTab = idx
        panels[pi].syncTabBar()
        surface.hostedView.removeFromSuperview()
        panels[pi].containerView.addSubview(surface.hostedView)
        layoutStrip()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.focusCurrentTerminal() }
    }

    func addNewPanel() {
        nlog("addNewPanel")
        guard GhosttyApp.shared.app != nil else { return }
        let surface = TerminalSurface(tabId: UUID(), context: GHOSTTY_SURFACE_CONTEXT_SPLIT, configTemplate: nil)
        let panel = makePanel(with: [surface])
        let live = liveIndices
        let insertAt = focusedIndex < live.count ? live[focusedIndex].panel + 1 : panels.count
        panels.insert(panel, at: insertAt)
        addSubview(panel.containerView)
        updateTabBarColors()
        focusedIndex += 1; scrollToReveal(); layoutStrip()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.focusCurrentTerminal() }
    }

    // MARK: - Focus

    func focusCurrentTerminal() {
        nlog("focusCurrentTerminal surface=\(focusedSurface?.id.uuidString.prefix(5) ?? "nil")")
        for p in panels where !p.closing {
            for tab in p.tabs {
                if let s = tab.surface { ghostty_surface_set_focus(s, false) }
            }
        }
        guard let surface = focusedSurface else { return }
        if let s = surface.surface { ghostty_surface_set_focus(s, true) }
        if let gv = findGhosttyNSView(in: surface.hostedView) { window?.makeFirstResponder(gv) }
    }

    private func findGhosttyNSView(in view: NSView) -> NSView? {
        if type(of: view) == GhosttyNSView.self { return view }
        for sub in view.subviews { if let v = findGhosttyNSView(in: sub) { return v } }
        return nil
    }

    // MARK: - Scroll

    override func scrollWheel(with event: NSEvent) {
        var dx = event.scrollingDeltaX; var dy = event.scrollingDeltaY
        if event.isDirectionInvertedFromDevice { dx = -dx; dy = -dy }
        let delta = abs(dx) > abs(dy) ? dx : dy
        targetOffset += delta * 2.0; targetOffset = max(0, targetOffset)
        let nf = nearestLive(forOffset: targetOffset)
        if nf != focusedIndex { focusedIndex = nf; focusCurrentTerminal() }
    }

    private func nearestLive(forOffset off: CGFloat) -> Int {
        var best = 0; var bestD = CGFloat.infinity; var x: CGFloat = 0; var li = 0
        for p in panels where !p.closing {
            let d = abs(x + pw(for: p) / 2 - off)
            if d < bestD { bestD = d; best = li }
            x += pw(for: p) + panelGap; li += 1
        }
        return best
    }

    override var acceptsFirstResponder: Bool { true }

    // MARK: - Display Link

    private func startDisplayLink() {
        CVDisplayLinkCreateWithActiveCGDisplays(&displayLink)
        guard let displayLink else { return }
        let cb: CVDisplayLinkOutputCallback = { _, _, _, _, _, ud -> CVReturn in
            let v = Unmanaged<NiriCanvasView>.fromOpaque(ud!).takeUnretainedValue()
            DispatchQueue.main.async { [weak v] in v?.tick() }
            return kCVReturnSuccess
        }
        CVDisplayLinkSetOutputCallback(displayLink, cb, Unmanaged.passUnretained(self).toOpaque())
        CVDisplayLinkStart(displayLink)
    }

    private func tick() {
        guard !panels.isEmpty, bounds.width > 1 else { return }

        // Accelerating scroll during drag (runs every frame)
        if isDragging {
            let scrollZone: CGFloat = 100
            let pt = dragMousePt
            let dt: CGFloat = 1.0 / 120.0
            let inZone: Bool
            var direction: CGFloat = 0
            var proximity: CGFloat = 0

            if pt.x < scrollZone && pt.x >= 0 {
                proximity = (scrollZone - pt.x) / scrollZone
                direction = -1
                inZone = true
            } else if pt.x > bounds.width - scrollZone && pt.x <= bounds.width {
                proximity = (pt.x - (bounds.width - scrollZone)) / scrollZone
                direction = 1
                inZone = true
            } else {
                inZone = false
            }

            if inZone {
                dragScrollDwell += dt
                // Acceleration: ramps up over 0.4s, quadratic ease-in
                let t = min(1.0, dragScrollDwell / 0.4)
                let accel = t * t  // 0 → 1 over 0.4s
                let speed = proximity * (2 + 18 * accel)  // 2-20 px/frame
                targetOffset += direction * speed
                scrollOffset += direction * speed
                // Clamp: can't scroll past the last panel's right edge
                let maxScroll = max(0, stripX(forLive: max(0, liveCount - 1)) + pw(for: panels[liveIndices.last!.panel]) - maxW + peekWidth)
                targetOffset = max(0, min(maxScroll, targetOffset))
                scrollOffset = max(0, min(maxScroll, scrollOffset))
                layoutStrip()
                // Update drop target & overlay to follow scrolled content
                updateDropTarget(at: pt, srcPi: dragSrcPi, srcTab: dragSrcTab, srcTabCount: dragSrcTabCount)
            } else {
                dragScrollDwell = 0
            }
        }

        // Detect window resize
        let currentWidth = bounds.width
        if currentWidth != lastBoundsWidth && currentWidth > 0 {
            lastBoundsWidth = currentWidth
            scrollToReveal()
        }

        var anyResizing = false
        for i in 0..<panels.count {
            let d = panels[i].targetWidth - panels[i].currentWidth
            if abs(d) < 0.001 { panels[i].currentWidth = panels[i].targetWidth }
            else { panels[i].currentWidth += d * 0.14; anyResizing = true }
        }
        if anyResizing {
            let live = liveIndices
            if focusedIndex < live.count {
                let ps = stripX(forLive: focusedIndex)
                let w = pw(for: panels[live[focusedIndex].panel])
                let vp = maxW
                if w >= vp { scrollOffset = ps }
                else { scrollOffset = max(ps + w - vp, min(ps, scrollOffset)) }
                scrollOffset = max(0, scrollOffset); targetOffset = scrollOffset
            }
        }
        var removed = false
        for i in (0..<panels.count).reversed() where panels[i].closing {
            panels[i].closeProgress -= 0.06
            if panels[i].closeProgress <= 0 {
                panels[i].containerView.removeFromSuperview(); panels.remove(at: i); removed = true
            }
        }
        if removed && liveCount == 0 { window?.close(); return }
        if !anyResizing {
            let diff = targetOffset - scrollOffset
            if abs(diff) < 0.3 { scrollOffset = targetOffset }
            else { scrollOffset += diff * springK }
        }
        layoutStrip()
    }
}

// MARK: - Window

final class NiriCanvasWindow: NSWindow {
    weak var canvasView: NiriCanvasView?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Ctrl+Tab / Ctrl+Shift+Tab: cycle tabs (keyCode 48 = Tab).
        // Must intercept here before ghostty can swallow it.
        if event.keyCode == 48 {
            let f = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if f.contains(.control) && !f.contains(.command) && !f.contains(.option) {
                let reverse = f.contains(.shift)
                canvasView?.cycleTab(reverse: reverse)
                return true
            }
        }
        if let c = canvasView, c.performKeyEquivalent(with: event) { return true }
        return super.performKeyEquivalent(with: event)
    }

    override func sendEvent(_ event: NSEvent) {
        // Focus-on-click: when user clicks on a terminal area, focus that panel
        if event.type == .leftMouseDown, let canvas = canvasView, !canvas.suppressHitTestFocus {
            let pt = canvas.convert(event.locationInWindow, from: nil)
            if let clickedLive = canvas.liveIndexAtPoint(pt), clickedLive != canvas.focusedIndex {
                canvas.focusedIndex = clickedLive
                canvas.scrollToReveal()
                canvas.focusCurrentTerminal()
            }
        }

        if event.type == .keyDown {
            let f = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let cmd = f.contains(.command)
            let ctrl = f.contains(.control)
            let opt = f.contains(.option)
            let ch = event.charactersIgnoringModifiers?.lowercased() ?? ""

            if ctrl && !cmd && !opt && (ch == "d" || event.characters == "\u{04}") {
                canvasView?.handleCtrlD(); return
            }
            if ctrl && !cmd && !opt && ch == "9" {
                canvasView?.switchToLastTabPublic(); return
            }
            if ctrl && !cmd && !opt, let n = Int(ch), n >= 1, n <= 8 {
                canvasView?.switchToTabPublic(n - 1); return
            }
            if (cmd || ctrl), let canvas = canvasView, canvas.performKeyEquivalent(with: event) { return }
            if cmd { return } // consume unhandled Cmd combos to prevent cmux crash
        }
        super.sendEvent(event)
    }
}

// MARK: - Controller

final class NiriCanvasWindowController: NSWindowController {
    private let canvasView: NiriCanvasView

    init() {
        let scr = NSScreen.main!.frame
        let win = NiriCanvasWindow(
            contentRect: NSRect(x: scr.midX - 700, y: scr.midY - 350, width: 1400, height: 700),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false
        )
        win.title = "Terminal Canvas"
        win.backgroundColor = NSColor(red: 0.06, green: 0.06, blue: 0.08, alpha: 1)
        win.minSize = NSSize(width: 800, height: 400)
        canvasView = NiriCanvasView(frame: win.contentView!.bounds)
        canvasView.autoresizingMask = [.width, .height]
        win.contentView!.addSubview(canvasView)
        win.canvasView = canvasView
        super.init(window: win)
    }

    required init?(coder: NSCoder) { fatalError() }

    func open(terminalCount: Int = 3, debugNoGhostty: Bool = false) {
        canvasView.debugNoGhostty = debugNoGhostty
        if debugNoGhostty {
            // Create dummy surfaces (won't actually init ghostty)
            canvasView.setSurfaces((0..<terminalCount).map { _ in
                TerminalSurface(tabId: UUID(), context: GHOSTTY_SURFACE_CONTEXT_SPLIT, configTemplate: nil)
            })
        } else {
            guard GhosttyApp.shared.app != nil else { return }
            canvasView.setSurfaces((0..<terminalCount).map { _ in
                TerminalSurface(tabId: UUID(), context: GHOSTTY_SURFACE_CONTEXT_SPLIT, configTemplate: nil)
            })
        }
        showWindow(nil); window?.makeKeyAndOrderFront(nil)
        if !debugNoGhostty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.canvasView.focusCurrentTerminal()
            }
        }
    }

    var canvas: NiriCanvasView { canvasView }
}
#endif
