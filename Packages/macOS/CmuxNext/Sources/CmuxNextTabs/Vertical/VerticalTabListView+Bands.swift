public import AppKit
public import CmuxNextDesign
import QuartzCore
import CmuxVisibleRows

/// The vertical tab list's rows on scrolling layers. The content is cut into bands one row pitch tall, aligned to the
/// rows, each a layer drawn once from what lies in it. A scroll moves the bands' container (the render server moves the pixels) and draws only the bands it reveals; a row's change
/// redraws its band. Bands out of view go, a few parked for the next scroll.
@MainActor final class VerticalTabBands {
    /// Holds the bands in content coordinates; its bounds origin is the scroll.
    let container = CALayer()
    /// The drop mark of a drag, over the bands.
    let dragMark = CALayer()
    /// The trailing hairline of a list widened over the content.
    let edgeLine = CALayer()
    /// Each band shown, by index (``band(_:)``).
    private(set) var shown: [Int: CALayer] = [:]
    private var parked: [CALayer] = []
    private var dirty: Set<Int> = []
    /// A band's height (a row and its spacing) and where band 0 starts, the first row's top (`VisibleBands`, the
    /// reveal math with no AppKit).
    private(set) var geometry = VisibleBands(pitch: 1, origin: 0)
    private(set) var width: CGFloat = 0
    /// The bands `shown` covers, as `VisibleBands.shown` gave them.
    private var shownRange: ClosedRange<Int>?
    /// Bands kept for reuse at most.
    static let parkLimit = 4

    init() {
        container.masksToBounds = true
        container.actions = ["bounds": NSNull(), "position": NSNull(), "sublayers": NSNull()]
        for layer in [dragMark, edgeLine] {
            layer.actions = ["bounds": NSNull(), "position": NSNull(), "hidden": NSNull(), "backgroundColor": NSNull(), "cornerRadius": NSNull()]
            layer.isHidden = true
        }
        dragMark.zPosition = 1
        container.addSublayer(dragMark)
    }

    /// Band layers alive, shown and parked.
    var alive: Int { shown.count + parked.count }

    /// The bands' geometry for a layout; a change drops every band's drawing (each draws again where it is).
    func setGeometry(pitch: CGFloat, origin: CGFloat, width: CGFloat) {
        let geometry = VisibleBands(pitch: Double(pitch), origin: Double(origin))
        guard geometry != self.geometry || width != self.width else { return }
        (self.geometry, self.width) = (geometry, width)
        for layer in shown.values { park(layer) }
        shown = [:]
        shownRange = nil
        dirty = []
    }

    /// The band content y falls in.
    func band(_ y: CGFloat) -> Int { geometry.band(Double(y)) }

    /// Band `index`'s rect in content coordinates.
    func rect(_ index: Int) -> CGRect {
        let span = geometry.span(index)
        return CGRect(x: 0, y: span.lowerBound, width: width, height: span.upperBound - span.lowerBound)
    }

    /// Shows the bands of content `minY..<maxY` and one more each side, within `0..<contentHeight`: the ones the move
    /// reveals are made and to draw (`takeDirty`), the ones it leaves go (`VisibleBands.revealed`, `VisibleWindow.change`).
    func show(minY: CGFloat, maxY: CGFloat, contentHeight: CGFloat) {
        let range = geometry.shown(minY: Double(minY), maxY: Double(maxY), contentHeight: Double(contentHeight))
        let left = shownRange.map { old in range.map { VisibleWindow.change(from: Range(old), to: Range($0)).dropped } ?? [Range(old)] } ?? []
        for index in left.joined() {
            guard let layer = shown.removeValue(forKey: index) else { continue }
            park(layer)
            dirty.remove(index)
        }
        for index in VisibleBands.revealed(from: shownRange, to: range).joined() where shown[index] == nil {
            let layer = parked.popLast() ?? Self.makeBand()
            layer.isHidden = false
            layer.frame = rect(index)
            if layer.superlayer == nil { container.insertSublayer(layer, below: dragMark) }
            shown[index] = layer
            dirty.insert(index)
        }
        shownRange = range
    }

    /// Marks the shown bands of content `minY..<maxY` to draw; true when one shows.
    @discardableResult
    func markDirty(minY: CGFloat, maxY: CGFloat) -> Bool {
        guard let touched = geometry.touching(minY: Double(minY), maxY: Double(maxY), in: shownRange) else { return false }
        dirty.formUnion(touched)
        return true
    }

    /// Marks every shown band to draw (a layout, a theme, a scale).
    func markAllDirty() { dirty = Set(shown.keys) }

    /// The bands to draw now; none after.
    func takeDirty() -> [(index: Int, layer: CALayer)] {
        defer { dirty = [] }
        return dirty.sorted().compactMap { index in shown[index].map { (index, $0) } }
    }

    private func park(_ layer: CALayer) {
        layer.contents = nil
        if parked.count < Self.parkLimit {
            layer.isHidden = true
            parked.append(layer)
        } else {
            layer.removeFromSuperlayer()
        }
    }

    private static func makeBand() -> CALayer {
        let layer = CALayer()
        layer.anchorPoint = .zero
        layer.contentsGravity = .topLeft
        layer.actions = ["bounds": NSNull(), "position": NSNull(), "contents": NSNull(), "hidden": NSNull()]
        return layer
    }
}

extension VerticalTabListView: ReduceTransparencyFollower {
    public override var wantsUpdateLayer: Bool { true }

    /// Group headers draw their glass opaque under Reduce Transparency: every band draws again.
    public func reduceTransparencyChanged() { invalidateAll() }

    /// Lays the bands out for the current layout (a new pitch, start or width redraws them all) and shows them.
    func layOutBands() {
        bands.setGeometry(pitch: metrics.rowHeight + metrics.rowSpacing, origin: metrics.verticalPadding, width: bounds.width)
        updateBands()
    }

    /// Moves the bands to the scroll and shows the ones the view shows now; the ones it adds draw in the next display
    /// pass (`updateLayer`). A scroll draws no band it had.
    func updateBands() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if bands.container.superlayer == nil, let layer {
            layer.addSublayer(bands.container)
            layer.addSublayer(bands.edgeLine)
        }
        bands.container.frame = bounds
        bands.container.bounds.origin = CGPoint(x: 0, y: scrollOffset)
        bands.show(minY: scrollOffset, maxY: scrollOffset + bounds.height, contentHeight: listLayout.contentHeight)
        CATransaction.commit()
        needsDisplay = true
    }

    /// The display pass: the panel's background while widened, the drag's mark, and the bands to draw.
    public override func updateLayer() {
        guard let layer else { return }
        let mark = drag.flatMap { $0.isActive ? $0.slot?.indicator : nil }
        performWithTheme {
            layer.backgroundColor = isHoverExpanded ? Palette.windowBackground.cgColor : nil
            bands.edgeLine.backgroundColor = Palette.separator.cgColor
            bands.dragMark.backgroundColor = Palette.accent.cgColor
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        bands.edgeLine.isHidden = !isHoverExpanded
        bands.edgeLine.frame = CGRect(x: bounds.maxX - 1, y: 0, width: 1, height: bounds.height)
        bands.dragMark.isHidden = mark == nil
        if let mark {
            bands.dragMark.frame = mark
            bands.dragMark.cornerRadius = min(mark.width, mark.height) / 2
        }
        let scale = window?.backingScaleFactor ?? 2
        for band in bands.takeDirty() { draw(band: band.layer, at: bands.rect(band.index), scale: scale) }
        CATransaction.commit()
    }

    /// Draws what lies in content rect `rect` (its rows, group lines and panes) into `band`'s image, upright.
    private func draw(band: CALayer, at rect: CGRect, scale: CGFloat) {
        let pixelsWide = Int((rect.width * scale).rounded(.up)), pixelsHigh = Int((rect.height * scale).rounded(.up))
        guard pixelsWide > 0, pixelsHigh > 0,
              let space = window?.colorSpace?.cgColorSpace ?? CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: pixelsWide, height: pixelsHigh, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else {
            band.contents = nil
            return
        }
        // Points, y down from the band's top, in content coordinates: the rows draw as they do in the view.
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: 0, y: rect.height)
        context.scaleBy(x: 1, y: -1)
        context.translateBy(x: -rect.minX, y: -rect.minY)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        drawsContent = true
        performWithTheme { drawRows(in: rect) }
        drawsContent = false
        NSGraphicsContext.restoreGraphicsState()
        band.contentsScale = scale
        band.contents = context.makeImage()
    }
}
