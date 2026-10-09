import AppKit
import Bonsplit
import QuartzCore

/// The trailing ends of every pane's own chrome, as pictures that ride the
/// pane's trailing edge through a slide.
///
/// Through a slide each pane stays laid out at its hidden-layout width, so
/// anything aligned to its trailing edge (tab bar action buttons, a browser
/// toolbar's buttons, a file viewer's path bar buttons, a fill-width tab's
/// close button) rests where the hidden layout put it and would be clipped
/// or uncovered by the pane's moving trailing edge. No list of such views is
/// kept: each pane's drawing outside its portal-hosted content is cut into
/// horizontal bands, and each band at the widest run of columns that are all
/// alike (the stretch between leading and trailing items). The part past
/// that seam is pictured and rides the trailing edge; the part before it
/// rides the leading edge with the pane. The seam falls in uniform space,
/// so the two halves meet invisibly however far apart the edges get.
@MainActor
struct SidebarSlidePaneChrome {
    struct Band {
        let image: CGImage
        /// In the content root's coordinates, in the layout pictured.
        let rect: NSRect
    }

    private enum VerticalEdge { case top, bottom }

    static let topChrome: CGFloat = 120
    static let bottomChrome: CGFloat = 80

    let bands: [ObjectIdentifier: [Band]]
    /// The panes that end at the content's trailing edge.
    let trailingEdge: Set<ObjectIdentifier>
    /// How each pane's tabs fade out before its trailing edge at rest.
    let tabFades: [ObjectIdentifier: TabFade]

    /// Bonsplit fades a pane's tabs over `fade` points ending `occlusion`
    /// points before its trailing edge (before the action lane, partly
    /// under it), and clears them past that.
    struct TabFade {
        var fade: CGFloat = 24
        var occlusion: CGFloat = 0

        /// Bonsplit's `TabBarActionLaneGeometry` for the app's backdrop
        /// effect: without a lane only an overflowing strip's 24 pt fade;
        /// with one, the effect's fade, ending a fraction of the lane in,
        /// or the whole lane when its buttons overflow it.
        static func at(lane: CGFloat, buttonCount: Int) -> Self {
            let effect = Workspace.bonsplitSplitButtonBackdropEffect()
            guard lane > 0, buttonCount > 0, effect.masksTabContent, effect.style != .hidden else { return Self() }
            let overflows = laneWidth(buttonCount: buttonCount, paneWidth: .infinity) > lane + 1
            return Self(fade: effect.contentFadeWidth, occlusion: overflows ? lane : lane * effect.contentOcclusionFraction)
        }
    }

    /// `covered` are the portal-hosted views' rects (terminals, browsers):
    /// rows they span are their own business.
    static func capture(in reference: NSView, layout: SidebarSlidePaneLayout, covered: [NSRect], buttonCount: Int) -> Self? {
        guard let trailing = layout.panes.values.map(\.maxX).max() else { return nil }
        // Each pane's tab bar rows: their trailing part is the action lane,
        // whose width Bonsplit fixes; the rest of a pane's chrome is cut at
        // a seam found in its pixels.
        var tabRows: [ObjectIdentifier: ClosedRange<CGFloat>] = [:]
        var lanes: [ObjectIdentifier: CGFloat] = [:]
        func findTabs(_ view: NSView) {
            if let tabBar = view as? BonsplitTabBarSlideWidthControlling, let pane = layout.pane(containing: view) {
                lanes[pane] = tabBar.slideActionLaneWidth
            }
            if SidebarSlideTabRowCapture.isTabItemRegion(view), !view.isHiddenOrHasHiddenAncestor, !view.visibleRect.isEmpty,
               let pane = layout.pane(containing: view) {
                let rect = reference.convert(view.visibleRect, from: view)
                tabRows[pane] = tabRows[pane].map { min($0.lowerBound, rect.minY)...max($0.upperBound, rect.maxY) } ?? rect.minY...rect.maxY
            }
            view.subviews.forEach(findTabs)
        }
        findTabs(reference)
        var bands: [ObjectIdentifier: [Band]] = [:]
        var trailingEdge: Set<ObjectIdentifier> = []
        // Each pane's strips outside its portal content; strips that share
        // a row range across panes are pictured in one pass.
        var strips: [ClosedRange<CGFloat>: [(id: ObjectIdentifier, pane: NSRect)]] = [:]
        var stripEdge: [ClosedRange<CGFloat>: VerticalEdge] = [:]
        for (id, pane) in layout.panes {
            if pane.maxX > trailing - 1 { trailingEdge.insert(id) }
            var rows: [ClosedRange<CGFloat>] = [pane.minY...pane.maxY]
            for rect in covered where rect.intersects(pane) && rect.width >= pane.width / 2 {
                rows = rows.flatMap { row -> [ClosedRange<CGFloat>] in
                    guard rect.minY < row.upperBound, rect.maxY > row.lowerBound else { return [row] }
                    return [row.lowerBound...max(row.lowerBound, rect.minY), min(row.upperBound, rect.maxY)...row.upperBound]
                        .filter { $0.upperBound - $0.lowerBound >= 4 }
                }
            }
            // The tab bar is a strip of its own.
            if let tabs = tabRows[id] {
                rows = rows.flatMap { row -> [ClosedRange<CGFloat>] in
                    guard tabs.lowerBound < row.upperBound, tabs.upperBound > row.lowerBound else { return [row] }
                    return [row.lowerBound...max(row.lowerBound, tabs.lowerBound), max(row.lowerBound, tabs.lowerBound)...min(row.upperBound, tabs.upperBound), min(row.upperBound, tabs.upperBound)...row.upperBound]
                        .filter { $0.upperBound - $0.lowerBound >= 4 }
                }
            }
            // Chrome lives at a stretch's top and bottom (tab bar, toolbars,
            // path bars, composers); content between rides with the pane.
            for row in rows {
                let parts = row.upperBound - row.lowerBound > Self.topChrome + Self.bottomChrome
                    ? [row.lowerBound...(row.lowerBound + Self.topChrome), (row.upperBound - Self.bottomChrome)...row.upperBound]
                    : [row]
                for (index, part) in parts.enumerated() {
                    strips[part, default: []].append((id, pane))
                    // Under a tab bar or other content, only the bar touching
                    // the strip's edge is chrome (a toolbar, a path bar, a
                    // composer); what follows is content.
                    stripEdge[part] = parts.count == 2 && index == 1 ? .bottom : .top
                }
            }
        }
        for (rows, panes) in strips {
            let minX = panes.map(\.pane.minX).min() ?? 0, maxX = panes.map(\.pane.maxX).max() ?? 0
            let rect = NSRect(x: minX, y: rows.lowerBound, width: maxX - minX, height: rows.upperBound - rows.lowerBound)
            guard let rep = reference.bitmapImageRepForCachingDisplay(in: rect) else { continue }
            reference.cacheDisplay(in: rect, to: rep)
            let scale = CGFloat(rep.pixelsWide) / max(1, rect.width)
            for (id, pane) in panes {
                // This pane's columns of the shared picture.
                let columns = Int(((pane.minX - minX) * scale).rounded())..<Int(((pane.maxX - minX) * scale).rounded())
                guard let paneRep = Self.columns(rep, columns) else { continue }
                let paneRect = NSRect(x: pane.minX, y: rect.minY, width: pane.width, height: rect.height)
#if DEBUG
                if let dir = ProcessInfo.processInfo.environment["CMUX_SIDEBAR_SLIDE_DUMP"], let png = paneRep.representation(using: .png, properties: [:]) {
                    let name = "strip-\(Int(pane.minX))-\(Int(rect.minY))-\(Int(rect.height))"
                    try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name + ".png"))
                    SidebarNavigationTimings.record("slide.strip \(name) px=\(paneRep.pixelsWide)x\(paneRep.pixelsHigh) bpp=\(paneRep.bitsPerPixel) seams=\(seams(in: paneRep).map { "\($0.rows):\($0.seam.map(String.init) ?? "-")" })")
                }
#endif
                let isTabBar = tabRows[id].map { abs($0.lowerBound - rows.lowerBound) < 1 && abs($0.upperBound - rows.upperBound) < 1 } ?? false
                // The tabs hold still (SidebarSlidePaneGlide.holdTabBars)
                // with Bonsplit's own lane hidden; the lane, whose width
                // Bonsplit reports, rides the trailing edge as a picture of
                // the lane alone.
                if isTabBar {
                    if let view = layout.view(id), let band = lanePicture(of: view, lane: lanes[id] ?? 0, reference: reference) {
                        bands[id, default: []].append(band)
                    }
                    continue
                }
                // A trailing part wider than half the pane is content that
                // happens to have a gap (text lines, a page), not a bar's
                // trailing items: it rides with the pane.
                let widest = Int(paneRep.pixelsWide / 2)
                var found = seams(in: paneRep)
                if stripEdge[rows] == .bottom { found = Array(found.suffix(1)) } else { found = Array(found.prefix(1)) }
                bands[id, default: []] += found.compactMap { band in
                    band.seam.flatMap { seam in
                        paneRep.pixelsWide - seam <= widest ? picture(paneRep, rect: paneRect, rows: band.rows, columns: seam..<paneRep.pixelsWide) : nil
                    }
                }
            }
        }
        bands = bands.filter { !$0.value.isEmpty }
        let tabFades = lanes.mapValues { TabFade.at(lane: $0, buttonCount: buttonCount) }
#if DEBUG
        SidebarNavigationTimings.record("slide.chrome buttons=\(buttonCount) panes=\(layout.panes.count) bands=\(bands.values.map { $0.map { "\(Int($0.rect.minY))+\(Int($0.rect.height)):\(Int($0.rect.width))" } })")
#endif
        return bands.isEmpty ? nil : Self(bands: bands, trailingEdge: trailingEdge, tabFades: tabFades)
    }

    /// The selected tab's indicator line at the top of a tab bar (Bonsplit's
    /// `activeIndicatorHeight`, 1.5 pt), with room for antialiasing.
    static let indicatorHeight: CGFloat = 2

    /// A pane's tab row views that draw up to its trailing edge: the tabs'
    /// scroll view, the selection chrome (the selected tab's indicator and
    /// the bar's bottom line), and other scroll views (the action lane's
    /// buttons among them).
    static func tabRowViews(in pane: NSView) -> (scrollViews: [NSView], selectionChromes: [NSView], otherScrollViews: [NSView]) {
        var scrollViews: [NSView] = [], selectionChromes: [NSView] = [], otherScrollViews: [NSView] = []
        func holdsTab(_ view: NSView) -> Bool {
            SidebarSlideTabRowCapture.isTabItemRegion(view) || view.subviews.contains(where: holdsTab)
        }
        func visit(_ view: NSView) {
            if NSStringFromClass(type(of: view)).contains("TabBarSelectionChromeView") {
                selectionChromes.append(view)
            } else if view is NSScrollView {
                if holdsTab(view) { scrollViews.append(view) } else { otherScrollViews.append(view) }
            } else {
                view.subviews.forEach(visit)
            }
        }
        visit(pane)
        return (scrollViews, selectionChromes, otherScrollViews)
    }

    /// A tab bar's action lane alone, on clear: its buttons, and the bar's
    /// bottom line under it, as Bonsplit draws them at rest. Nothing else
    /// of the bar is in it (tab content under the lane, the ground behind
    /// the bar), so the live tabs fade out under it untouched.
    static func lanePicture(of pane: NSView, lane: CGFloat, reference: NSView) -> Band? {
        let views = tabRowViews(in: pane)
        guard lane > 0, let chrome = views.selectionChromes.first else { return nil }
        let bar = pane.convert(chrome.bounds, from: chrome)
        let rect = NSRect(x: bar.maxX - lane, y: bar.minY, width: lane, height: bar.height)
        let buttons = views.otherScrollViews.filter { view in
            let frame = pane.convert(view.bounds, from: view)
            return frame.maxX > rect.minX + 1 && frame.minY < bar.maxY && frame.maxY > bar.minY
        }
        let scale = pane.window?.backingScaleFactor ?? 2
        let width = Int((rect.width * scale).rounded()), height = Int((rect.height * scale).rounded())
        guard !buttons.isEmpty, width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        func draw(_ view: NSView, below: CGFloat?) {
            let local = view.convert(rect, from: pane)
            guard let rep = view.bitmapImageRepForCachingDisplay(in: local) else { return }
            view.cacheDisplay(in: local, to: rep)
            guard let image = rep.cgImage else { return }
            context.saveGState()
            // Only rows below the top `below` points (the bottom line, not
            // the selected tab's indicator: the live one is faded instead).
            if let below { context.clip(to: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height) - below * scale)) }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            context.restoreGState()
        }
        draw(chrome, below: indicatorHeight)
        buttons.forEach { draw($0, below: nil) }
        guard let image = context.makeImage() else { return nil }
        return Band(image: image, rect: reference.convert(rect, from: pane))
    }

    /// A mask for a layer of a pane's tab row that fades its drawing out
    /// before `edge` (the pane's trailing edge, in the layer's coordinates)
    /// the way Bonsplit fades tabs at rest: kept up to `fade + occlusion`
    /// before the edge, faded over `fade`, cleared past. The rows `keep`
    /// (the bar's bottom line) are kept up to their own edge instead. The
    /// slide rides it on the pane's moving trailing edge.
    static func trailingFadeMask(for layer: CALayer, edge: CGFloat, fade: CGFloat, occlusion: CGFloat, keep: (rows: ClosedRange<CGFloat>, edge: CGFloat)?) -> CALayer {
        let bleed: CGFloat = 10_000
        let mask = CALayer()
        mask.anchorPoint = .zero
        mask.bounds = layer.bounds
        mask.position = layer.bounds.origin
        let fadeStart = edge - occlusion - fade
        func solid(_ x1: CGFloat, _ y0: CGFloat, _ y1: CGFloat) {
            let part = CALayer()
            part.backgroundColor = NSColor.black.cgColor
            part.frame = CGRect(x: -bleed, y: y0, width: x1 + bleed, height: y1 - y0)
            mask.addSublayer(part)
        }
        func band(_ y0: CGFloat, _ y1: CGFloat) {
            guard y1 > y0 else { return }
            solid(fadeStart, y0, y1)
            guard fade > 0 else { return }
            let gradient = CAGradientLayer()
            gradient.colors = [NSColor.black.cgColor, NSColor.black.withAlphaComponent(0).cgColor]
            gradient.startPoint = CGPoint(x: 0, y: 0.5)
            gradient.endPoint = CGPoint(x: 1, y: 0.5)
            gradient.frame = CGRect(x: fadeStart, y: y0, width: fade, height: y1 - y0)
            mask.addSublayer(gradient)
        }
        let top = layer.bounds.minY - bleed, bottom = layer.bounds.maxY + bleed
        if let keep {
            band(top, keep.rows.lowerBound)
            band(keep.rows.upperBound, bottom)
            solid(keep.edge, keep.rows.lowerBound, keep.rows.upperBound)
        } else {
            band(top, bottom)
        }
        return mask
    }

    /// Bonsplit's action lane: 6 pt leading and 8 pt trailing padding, 22 pt
    /// per button and 4 pt between them, all of up to five buttons shown;
    /// past five it is capped near a quarter of the pane.
    nonisolated static func laneWidth(buttonCount: Int, paneWidth: CGFloat) -> CGFloat {
        guard buttonCount > 0 else { return 0 }
        func width(_ count: Int) -> CGFloat { 10 + 26 * CGFloat(count) }
        guard buttonCount > 5 else { return width(buttonCount) }
        return min(width(buttonCount), max(paneWidth / 4, width(5)))
    }

    /// Every pixel of the row the same.
    private static func rowIsUniform(_ row: UnsafeMutablePointer<UInt8>, width: Int) -> Bool {
        let pixels = UnsafeRawPointer(row).assumingMemoryBound(to: UInt32.self)
        let first = pixels[0]
        for index in 1..<width where pixels[index] != first { return false }
        return true
    }

    /// A copy of some pixel columns of `rep`, as its own bitmap.
    private static func columns(_ rep: NSBitmapImageRep, _ columns: Range<Int>) -> NSBitmapImageRep? {
        let clamped = max(0, columns.lowerBound)..<min(rep.pixelsWide, columns.upperBound)
        guard clamped.count > 2, let image = rep.cgImage?.cropping(to: CGRect(x: clamped.lowerBound, y: 0, width: clamped.count, height: rep.pixelsHigh)) else { return nil }
        let copy = NSBitmapImageRep(cgImage: image)
        copy.size = NSSize(width: rep.size.width * CGFloat(clamped.count) / CGFloat(rep.pixelsWide), height: rep.size.height)
        return copy
    }

    /// Crops `columns` x `rows` (pixels) of `rep`, which pictures `rect`.
    static func picture(_ rep: NSBitmapImageRep, rect: NSRect, rows: Range<Int>, columns: Range<Int>) -> Band? {
        let scale = CGFloat(rep.pixelsWide) / max(1, rect.width)
        let crop = CGRect(x: columns.lowerBound, y: rows.lowerBound, width: columns.count, height: rows.count)
        guard crop.width >= scale * 2, let picture = rep.cgImage?.cropping(to: crop) else { return nil }
        return Band(image: picture, rect: NSRect(
            x: rect.minX + CGFloat(columns.lowerBound) / scale,
            y: rect.minY + CGFloat(rows.lowerBound) / scale,
            width: CGFloat(columns.count) / scale,
            height: CGFloat(rows.count) / scale
        ))
    }

    /// The bands of a picture (pixel rows) and each band's seam (the pixel
    /// column starting its trailing part). A band is the rows between two
    /// rows alike all the way across, split further only where no run of
    /// columns stays alike across all of them; one seam serves every row of
    /// a bar, so nothing spanning rows (a tab, a pill) is torn. The
    /// seam ends the widest such run, so the trailing part is just the
    /// trailing items: the stretch stays live and can shrink as far as the
    /// docked layout's own stretch without the picture covering anything.
    /// Of near-equal runs (centred content), the trailing-most. Rows alike
    /// all the way across fit any band; bands with no run have no seam.
    static func seams(in rep: NSBitmapImageRep) -> [(rows: Range<Int>, seam: Int?)] {
        guard let data = rep.bitmapData, rep.bitsPerPixel == 32 else { return [] }
        let width = rep.pixelsWide, height = rep.pixelsHigh, rowBytes = rep.bytesPerRow
        let step = max(1, Int((CGFloat(width) / max(1, rep.size.width)).rounded()))
        let columns = (width - 1) / step
        guard columns > 2, height > 0 else { return [] }
        // Runs at keypress time on full panes and overlays: no allocation
        // per row, plain loops over the pixels.
        let current = UnsafeMutableBufferPointer<Bool>.allocate(capacity: columns)
        let next = UnsafeMutableBufferPointer<Bool>.allocate(capacity: columns)
        defer {
            current.deallocate()
            next.deallocate()
        }
        func fill(_ buffer: UnsafeMutableBufferPointer<Bool>, row y: Int, and previous: UnsafeMutableBufferPointer<Bool>?) {
            let pixels = UnsafeRawPointer(data + y * rowBytes).assumingMemoryBound(to: UInt32.self)
            var column = 0, offset = 0
            if let previous {
                while column < columns {
                    buffer[column] = previous[column] && pixels[offset] == pixels[offset + step]
                    column += 1
                    offset += step
                }
            } else {
                while column < columns {
                    buffer[column] = pixels[offset] == pixels[offset + step]
                    column += 1
                    offset += step
                }
            }
        }
        // A run reaching the trailing edge is padding past the last item,
        // not a stretch between items.
        func widest(_ buffer: UnsafeMutableBufferPointer<Bool>) -> Int {
            var best = 0, run = 0
            for column in 0..<columns {
                run = buffer[column] ? run + 1 : 0
                if run > best, column < columns - 1 || run == columns { best = run }
            }
            return best
        }
        /// Start of the trailing-most run at least 60% of the widest.
        /// End of the widest run (where the trailing items start); of
        /// near-equal ones (centred content between margins), the
        /// trailing-most.
        func seamEnd(_ buffer: UnsafeMutableBufferPointer<Bool>, widest: Int) -> Int {
            var found = 0, run = 0
            for column in 0..<columns - 1 {
                run = buffer[column] ? run + 1 : 0
                if run > 0, run >= widest - 2, !buffer[column + 1] { found = column }
            }
            return found
        }
        var result: [(rows: Range<Int>, seam: Int?)] = []
        func close(_ rows: Range<Int>) {
            let best = widest(current)
            guard best > 0, best < columns * 9 / 10 else {
                result.append((rows, nil))
                return
            }
            result.append((rows, (seamEnd(current, widest: best) + 1) * step))
        }
        // Rows alike all the way across (padding, a separator) end a band:
        // a bar and the line or bar under it are pictured apart.
        var bandStart = 0
        var inBand = false
        var previousRow = 0
        var y = 0
        while y < height {
            let row = data + y * rowBytes
            if Self.rowIsUniform(row, width: width) {
                if inBand { close(bandStart..<y) }
                inBand = false
                y += step
                continue
            }
            if !inBand {
                fill(current, row: y, and: nil)
                bandStart = y
                inBand = true
            } else if memcmp(row, data + previousRow * rowBytes, width * 4) != 0 {
                fill(next, row: y, and: current)
                if widest(next) >= 4 {
                    _ = current.update(fromContentsOf: next)
                } else {
                    close(bandStart..<y)
                    bandStart = y
                    fill(current, row: y, and: nil)
                }
            }
            previousRow = y
            y += step
        }
        if inBand { close(bandStart..<height) }
        return result
    }

    /// Fallback without per-pane motion: still pictures of the trailing-edge
    /// panes' bands, which rest at the same x in both layouts.
    func makeStillOverlays(above reference: NSView, in container: NSView) -> [NSView] {
        bands.filter { trailingEdge.contains($0.key) }.values.flatMap { $0 }.map { band in
            let view = SidebarSlidePictureView(frame: container.convert(band.rect, from: reference))
            view.wantsLayer = true
            view.image = band.image
            container.addSubview(view, positioned: .above, relativeTo: nil)
            return view
        }
    }
}

/// Shows a picture and takes no clicks. Drawing goes through `updateLayer`,
/// so a display pass (the atomic commit runs one) keeps the picture instead
/// of repainting the layer with an empty `draw(_:)`.
final class SidebarSlidePictureView: NSView {
    var image: CGImage? {
        didSet { layer?.contents = image }
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.contents = image
        layer?.contentsGravity = .resize
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
