import AppKit
import CmuxNextDesign
import QuartzCore

/// DEV and NIGHTLY (Debug menu > Sidebar States Playground): draws the real sidebar (``SidebarView`` over
/// ``SidebarStatesPlaygroundFixture``) for one column and appearance, and cuts it into one cell per state, each with
/// the trailing marks the row laid out and the guides measured on the rows.
///
/// `sidebar.density` and `sidebar.textSize` are app-wide and read at layout time, so two live sidebars at two
/// densities cannot share one process: the renderer sets the column's pair on `design`, lays the sidebar out in its
/// own borderless window, takes its pixels and measures it, then puts the pair back. The playground shows those
/// pixels, so every cell is what the real views drew.
@MainActor
struct SidebarStatesPlaygroundRenderer {
    /// The settings the real views read (`DesignSettings.shared` in the app).
    var design: DesignSettings
    /// The sheets' themes.
    var themes: SidebarStatesPlaygroundThemes
    /// The sidebar's width: the app's default sidebar width.
    var width: CGFloat = 260
    /// Tall enough that every row of the fixture is on screen at the Expanded density and the Larger text size.
    var height: CGFloat = 1500
    /// The shots' pixels per point, at least (the window's own scale when higher).
    var pixelScale: CGFloat = 2
    /// Air above and below a row in its cell.
    static let rowPad: CGFloat = 4

    /// Every state's cell at `column` in `appearance`.
    func cells(_ column: SidebarStatesPlaygroundColumn,
               _ appearance: SidebarStatesPlaygroundAppearance) -> [SidebarStatesPlaygroundState: SidebarStatesPlaygroundCell] {
        let saved = design.sidebarSections
        design.sidebarSections.density = column.density
        design.sidebarSections.textSize = column.textSize
        defer { design.sidebarSections = saved }
        let fixture = SidebarStatesPlaygroundFixture()
        let window = NSWindow(contentRect: NSRect(x: -40_000, y: -40_000, width: width, height: height), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isExcludedFromWindowsMenu = true
        window.ignoresMouseEvents = true
        window.alphaValue = 0 // drawn into a bitmap only; never seen
        window.appearance = appearance.appearance
        defer {
            window.orderOut(nil)
            window.close()
        }
        let root = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        root.wantsLayer = true
        root.appearance = window.appearance
        window.contentView = root
        let scope = ThemeScope(level: .room)
        if let theme = themes.theme(appearance) { scope.setOverride(theme.spec, input: theme.input, animated: false) }
        scope.root(root)
        root.layer?.backgroundColor = scope.perform { Palette.windowBackground.withAlphaComponent(1) }.cgColor
        let sidebar = SidebarView(model: fixture.model(expanded: column.density == .expanded), design: design)
        sidebar.frame = root.bounds
        root.addSubview(sidebar)
        window.orderFrontRegardless()
        let list = sidebar.list
        list.openDoneFolds.insert(.archive) // the archived row shows under the open Archive section
        list.onGroupEditorItem = { _, _ in } // a group header offers its + (the empty group's) only with a handler
        sidebar.layoutSubtreeIfNeeded()
        list.reload(animated: false)
        sidebar.layoutSubtreeIfNeeded()
        list.fitToClip()
        // The window is never on screen: draw the rows as on a shown window, so the spinner is the turning mark.
        list.setWindowVisible(true)
        sidebar.beginRename(workspace: SidebarStatesPlaygroundFixture.renaming)
        root.layoutSubtreeIfNeeded()
        // Hovered last, after the list's own layout: the hovered row and the empty group's header (its + shows on hover).
        list.setHovered(.workspace(SidebarStatesPlaygroundFixture.hovered))
        for key in [SidebarRowKey.workspace(SidebarStatesPlaygroundFixture.hovered), .group(SidebarStatesPlaygroundFixture.empty)] {
            guard let row = list.rowViews[key] else { continue }
            row.isHovered = true
            row.needsLayout = true
            row.layoutSubtreeIfNeeded()
        }
        let shot = Self.draw(root, pixelScale: pixelScale)
        let scale = shot.map { CGFloat($0.width) / root.bounds.width } ?? 1
        let pixels = shot.flatMap(SidebarStatesPlaygroundPixels.init)
        let guides = Self.guides(list, root: root)
        var cells: [SidebarStatesPlaygroundState: SidebarStatesPlaygroundCell] = [:]
        for state in SidebarStatesPlaygroundState.allCases {
            let view = Self.view(fixture.ref(for: state), in: list)
            cells[state] = cell(state, view: view, root: root, shot: shot, pixels: pixels, scale: scale, guides: guides, list: list)
        }
        if list.inlineRename.isActive { list.inlineRename.end(commit: false) }
        list.setHovered(nil)
        return cells
    }

    /// Draws every view under `root` as laid out (no layout pass, so the hover set after the list's layout stays), then
    /// returns its pixels at `pixelScale` pixels per point at least: a 1x screen (a fleet display) still gives a 2x shot,
    /// its layers drawn again at that scale, so a size critique reads half points.
    private static func draw(_ root: NSView, pixelScale: CGFloat) -> CGImage? {
        func all(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(all) }
        let scale = max(pixelScale, root.window?.backingScaleFactor ?? 1)
        func rescale(_ layer: CALayer) {
            if layer.contentsScale != scale {
                layer.contentsScale = scale
                // Text and shapes draw again at the new scale; an image layer keeps its contents.
                if layer is CATextLayer || layer.delegate is NSView { layer.setNeedsDisplay() }
            }
            layer.sublayers?.forEach(rescale)
        }
        if let layer = root.layer { rescale(layer) }
        for view in all(root) {
            view.layer?.removeAllAnimations()
            view.needsDisplay = true
            view.displayIfNeeded()
        }
        root.layer?.displayIfNeeded()
        let size = root.bounds.size
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = size
        root.cacheDisplay(in: root.bounds, to: rep)
        return rep.cgImage
    }

    /// The real row view that draws `ref`, if the list drew it.
    private static func view(_ ref: SidebarStatesPlaygroundFixture.Ref, in list: SidebarListView) -> NSView? {
        switch ref {
        case let .list(key): list.rowViews[key]
        case let .band(block, item): (list.rowViews[.block(block)] as? SidebarBlockRowView)?.region.itemViews[item]
        }
    }

    /// The leading inset (the idle row's title start, it has no icon) and the trailing column (the open group
    /// header's chevron center), as x in `root`.
    private static func guides(_ list: SidebarListView, root: NSView) -> (leading: CGFloat?, column: CGFloat?) {
        let idle = list.rowViews[.workspace(SidebarStatesPlaygroundFixture.idle)] as? WorkspaceRowView
        let leading = idle.map { root.convert($0.title.frame, from: $0).minX }
        let header = list.rowViews[.group(SidebarStatesPlaygroundFixture.open)]
        let column = header.flatMap { header in header.debugDisclosure.map { root.convert($0.frame, from: header).midX } }
        return (leading, column)
    }

    private func cell(_ state: SidebarStatesPlaygroundState, view: NSView?, root: NSView, shot: CGImage?,
                      pixels: SidebarStatesPlaygroundPixels?, scale: CGFloat,
                      guides: (leading: CGFloat?, column: CGFloat?), list: SidebarListView) -> SidebarStatesPlaygroundCell {
        let empty = SidebarStatesPlaygroundCell(state: state, image: nil, scale: scale, size: CGSize(width: width, height: 0),
                                                rowFrame: .zero, leadingGuideX: guides.leading, columnGuideX: guides.column,
                                                marks: [], rowView: nil)
        guard let view, view.window != nil, !view.isHiddenOrHasHiddenAncestor else { return empty }
        let row = root.convert(view.bounds, from: view)
        // The cell spans the sidebar's width, so its guides line up from row to row; top-left origin from here on.
        let box = NSRect(x: 0, y: row.minY - Self.rowPad, width: width, height: row.height + 2 * Self.rowPad).intersection(root.bounds)
        guard !box.isEmpty else { return empty }
        func local(_ rect: NSRect) -> CGRect { CGRect(x: rect.minX - box.minX, y: box.maxY - rect.maxY, width: rect.width, height: rect.height) }
        let pixelBox = CGRect(x: box.minX * scale, y: (root.bounds.height - box.maxY) * scale, width: box.width * scale,
                              height: box.height * scale).integral
        let marks = Self.marks(in: view, root: root, column: guides.column).map { mark, rect in
            var mark = mark
            mark.frame = local(rect)
            let ink = pixels?.inkBox(in: CGRect(x: rect.minX * scale, y: (root.bounds.height - rect.maxY) * scale,
                                                width: rect.width * scale, height: rect.height * scale))
            mark.ink = ink.map { CGSize(width: $0.width / scale, height: $0.height / scale) }
            return mark
        }
        let bars = Self.bars(beside: view, row: row, list: list, root: root).map { bar, rect in
            var bar = bar
            bar.frame = local(rect)
            return bar
        }
        return SidebarStatesPlaygroundCell(state: state, image: shot?.cropping(to: pixelBox), scale: scale, size: box.size,
                                           rowFrame: local(row), leadingGuideX: guides.leading.map { $0 - box.minX },
                                           columnGuideX: guides.column.map { $0 - box.minX }, marks: marks, bars: bars,
                                           rowView: String(describing: type(of: view)))
    }

    /// The leading bars beside `view` (Lawrence msg 19775): a colored row's color rail, and the rail of the open group
    /// whose span covers the row, with their frames in `root` and the radius their layers give each end.
    private static func bars(beside view: NSView, row: NSRect, list: SidebarListView,
                             root: NSView) -> [(SidebarStatesPlaygroundBar, NSRect)] {
        var candidates: [NSView] = []
        if let workspace = view as? WorkspaceRowView { candidates.append(workspace.colorRail) }
        func lines(_ parent: NSView) {
            for child in parent.subviews {
                if child is GroupLineView { candidates.append(child) } else if !(child is SidebarRowView) { lines(child) }
            }
        }
        lines(list)
        return candidates.compactMap { bar in
            guard bar.superview != nil, !bar.isHiddenOrHasHiddenAncestor, bar.alphaValue > 0.05, let layer = bar.layer else { return nil }
            let rect = root.convert(bar.bounds, from: bar)
            guard !rect.isEmpty, rect.maxY > row.minY + 1, rect.minY < row.maxY - 1 else { return nil }
            // Which corners round, as the screen shows them: a flipped layer's max-y corners are its bottom.
            let flipped = layer.contentsAreFlipped()
            let bottomCorners: CACornerMask = flipped ? [.layerMinXMaxYCorner, .layerMaxXMaxYCorner] : [.layerMinXMinYCorner, .layerMaxXMinYCorner]
            let topCorners: CACornerMask = flipped ? [.layerMinXMinYCorner, .layerMaxXMinYCorner] : [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
            let radius = min(layer.cornerRadius, min(rect.width, rect.height) / 2)
            let top = layer.maskedCorners.isDisjoint(with: topCorners) ? 0 : radius
            let bottom = layer.maskedCorners.isDisjoint(with: bottomCorners) ? 0 : radius
            let name = String(describing: type(of: bar))
            return (SidebarStatesPlaygroundBar(view: name, frame: .zero, topRadius: top, bottomRadius: bottom), rect)
        }
    }

    /// The trailing marks `row` lays out and shows (a status indicator that draws, a dot, the chevron, a button, an
    /// image) whose center is within two slots of the trailing column, leading to trailing, with their frames in `root`.
    private static func marks(in row: NSView, root: NSView, column: CGFloat?) -> [(SidebarStatesPlaygroundMark, NSRect)] {
        let reach = SidebarStyle.trailingSlotPitch * 2 + SidebarStyle.trailingSlotSide / 2
        var found: [(SidebarStatesPlaygroundMark, NSRect)] = []
        func visit(_ view: NSView, alpha: CGFloat) {
            guard !view.isHidden else { return }
            let alpha = alpha * view.alphaValue * CGFloat(view.layer?.opacity ?? 1)
            guard alpha > 0.05 else { return }
            var state: String?
            switch view {
            case let indicator as StatusIndicatorView:
                guard indicator.state != .idle else { return }
                state = Self.name(indicator.state)
            case is UnreadBadgeView, is DisclosureChevronView, is ClickableButton, is DecorativeImageView:
                break
            default:
                view.subviews.forEach { visit($0, alpha: alpha) }
                return
            }
            let rect = root.convert(view.bounds, from: view)
            guard !rect.isEmpty, view.bounds.width > 0.5, column.map({ abs(rect.midX - $0) <= reach }) ?? true else { return }
            found.append((SidebarStatesPlaygroundMark(view: String(describing: type(of: view)), state: state, frame: .zero, ink: nil), rect))
        }
        row.subviews.forEach { visit($0, alpha: 1) }
        return found.sorted { $0.1.midX < $1.1.midX }
    }

    private static func name(_ state: StatusIndicatorState) -> String {
        switch state {
        case .idle: "idle"
        case .busy: "busy"
        case .paused: "paused"
        case .working: "working"
        case .waiting: "waiting"
        case .error: "error"
        case .success: "success"
        }
    }
}
