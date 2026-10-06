#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// A long text row (LongText.swift) without a bubble-sized bitmap: the bubble is a
/// three-slice mask on the cell's fill layer, the text is tiles of 16 lines that
/// exist only near the viewport. shared/LONG-MESSAGES.md.
enum TiledBubble {
    static let linesPerTile = 16
    /// Glyph overflow above and below a tile's line slots (emoji, diacritics).
    static let overflow: CGFloat = 12
    static let emptyImage: CGImage = WideBitmap.make(size: CGSize(width: 1, height: 1), scale: 1, opaque: false) { _ in }

    static func applies(_ spec: RowSpec) -> Bool { LongText.isLongRow(spec) }

    /// RowCell.configure for a long text row (inside the cell's transaction).
    static func configure(_ cell: RowCell, _ spec: RowSpec) {
        guard case let .part(p) = spec.kind, case let .text(t, _) = p.part else { return }
        let body = cell.tiled ?? TiledBody()
        cell.tiled = body
        body.attach(cell)
        body.set(spec: spec, row: p, layout: LongTextStore.shared.layout(t, width: spec.width), cell: cell)
        cell.bitmap.contents = emptyImage
        cell.bitmap.isHidden = true
        body.update(cell)
    }

    /// Draw one tile: lines [chunk*16, chunk*16+16) of a block, unclipped, at their baselines.
    static func render(_ bl: BlockLayout, chunk: Int, outgoing: Bool, width: CGFloat, scale: CGFloat) -> CGImage {
        let lh = Fixture.lineHeight
        let size = CGSize(width: width, height: CGFloat(linesPerTile) * lh + 2 * overflow)
        return WideBitmap.make(size: size, scale: scale, opaque: false) { ctx in
            draw(bl, chunk: chunk, outgoing: outgoing, in: ctx, top: 0)
        }
    }
    /// The tile's lines into `ctx`, the tile's top at y `top` (checks draw tiles and the whole in one context).
    static func draw(_ bl: BlockLayout, chunk: Int, outgoing: Bool, in ctx: CGContext, top: CGFloat) {
        let lh = Fixture.lineHeight
        let attr = bl.attributed(outgoing: outgoing)
        let a = chunk * linesPerTile, b = min(bl.lines.count, a + linesPerTile)
        guard a < b else { return }
        for j in a..<b where bl.lines[j].length > 0 {
            let l = CTLineCreateWithAttributedString(attr.attributedSubstring(from: bl.lines[j]))
            ctx.saveGState()
            ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
            ctx.textPosition = CGPoint(x: Fixture.bubblePadX,
                                       y: top + overflow + (Fixture.textBaseline - Fixture.bubblePadY) + CGFloat(j - a) * lh)
            CTLineDraw(l, ctx)
            ctx.restoreGState()
        }
    }

    static let tileQueue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 2
        q.qualityOfService = .userInitiated
        q.name = "longtext.tiles"
        return q
    }()
}

/// Bubble outline as a three-slice image: top cap, a 1 px middle that stretches,
/// bottom cap with the tail. Pixel aligned; the body's sub-pixel x is baked in.
enum BubbleSlices {
    static let cap: CGFloat = 32, pad: CGFloat = 24, vpad: CGFloat = 8
    private static var cache: [String: CGImage] = [:]
    static func image(bodyWidth: CGFloat, phase: CGFloat, outgoing: Bool, tail: Bool, scale: CGFloat) -> CGImage {
        let k = "\(bodyWidth)|\(phase)|\(outgoing)|\(tail)|\(scale)"
        if let i = cache[k] { return i }
        if cache.count > 64 { cache.removeAll() }
        let w = (ceil((bodyWidth + 2 * pad + 1) * scale)) / scale
        let size = CGSize(width: w, height: 2 * cap + 2 * vpad)
        let img = WideBitmap.make(size: size, scale: scale, opaque: false) { ctx in
            UIColor.black.setFill()
            BubblePath.make(body: CGRect(x: pad + phase, y: vpad, width: bodyWidth, height: 2 * cap), outgoing: outgoing, tail: tail).fill()
        }
        cache[k] = img
        return img
    }
}

/// Live tile and measurement counters (bench evidence).
enum TiledStats {
    static var tilesMain = 0, tilesAsync = 0, tilesCancelled = 0
    /// Visible tiles without pixels at the end of a layout pass (text pop-in).
    static var blankVisible = 0
    static var liveTiles = 0, maxLiveTiles = 0
}

/// Rendered tiles, LRU by bytes (main thread).
final class TileCache {
    static let shared = TileCache()
    struct Key: Hashable {
        var lineage: Int; var start: Int; var end: Int; var final: Bool; var column: CGFloat
        var chunk: Int; var outgoing: Bool; var scale: CGFloat; var palette: Int
        var slot: Slot { Slot(lineage: lineage, start: start, chunk: chunk) }
    }
    struct Slot: Hashable { var lineage: Int; var start: Int; var chunk: Int }
    var budget: Int = {
        let a = ProcessInfo.processInfo.arguments
        return (a.firstIndex(of: "--tile-cache-mb").flatMap { $0 + 1 < a.count ? Int(a[$0 + 1]) : nil } ?? 48) << 20
    }()
    private var map: [Key: (CGImage, Int, Int)] = [:]
    private var tick = 0
    private(set) var bytes = 0
    func get(_ k: Key) -> CGImage? {
        guard let e = map[k] else { return nil }
        tick += 1
        map[k] = (e.0, e.1, tick)
        return e.0
    }
    func put(_ k: Key, _ img: CGImage) {
        if let old = map[k] { bytes -= old.1 }
        let b = img.bytesPerRow * img.height
        tick += 1
        map[k] = (img, b, tick)
        bytes += b
        guard bytes > budget else { return }
        var freed: [CGImage] = []
        for (key, e) in map.sorted(by: { $0.value.2 < $1.value.2 }) {
            if bytes <= budget * 4 / 5 { break }
            map[key] = nil
            bytes -= e.1
            freed.append(e.0)
        }
        Reclaimer.release(freed)
    }
    var count: Int { map.count }
    func removeAll() { Reclaimer.release(map.values.map(\.0)); map.removeAll(); bytes = 0 }
}

/// The long-text layers of one RowCell.
final class TiledBody {
    let container = CALayer()
    let shape = CALayer()
    private var live: [TileCache.Key: CALayer] = [:]
    private var pool: [CALayer] = []
    private var pending: [TileCache.Key: Operation] = [:]
    private(set) var layout: LongTextLayout?
    private var row: PartRow?
    private var spec: RowSpec?
    private var body: CGRect = .zero
    private static let noActions: [String: CAAction] = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull(),
                                                        "hidden": NSNull(), "frame": NSNull(), "contentsCenter": NSNull()]

    /// Folded (LongTextFold): head and tail lines in clipped regions, the band between.
    let headClip = CALayer(), tailClip = CALayer(), band = CALayer()
    private(set) var folded = false
    /// The "Show all N lines" band in cell coordinates (zero when not folded).
    private(set) var bandRect: CGRect = .zero
    private var bandKey = ""

    init() {
        for l in [container, shape, headClip, tailClip, band] { l.actions = TiledBody.noActions }
        container.masksToBounds = false
        headClip.masksToBounds = true
        tailClip.masksToBounds = true
        container.addSublayer(headClip)
        container.addSublayer(tailClip)
        container.addSublayer(band)
    }

    var isActive: Bool { spec != nil }
    /// Visible tiles without pixels now (bench).
    private var visibleKeys = Set<TileCache.Key>()
    var lastBlank: Int { spec == nil ? 0 : visibleKeys.reduce(0) { $0 + (live[$1]?.contents == nil ? 1 : 0) } }

    func attach(_ cell: RowCell) {
        if container.superlayer !== cell.contentView.layer {
            cell.contentView.layer.insertSublayer(container, above: cell.fillContainer)
        }
        container.isHidden = false
        if cell.fillContainer.mask !== shape { cell.fillContainer.mask = shape }
    }

    /// Back to a normal row (or into the pool): tiles return to the pool.
    func detach(_ cell: RowCell) {
        guard spec != nil || container.superlayer != nil else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for (_, l) in live { l.contents = nil; l.isHidden = true; pool.append(l) }
        live.removeAll()
        for (_, op) in pending { op.cancel() }
        pending.removeAll()
        container.isHidden = true
        cell.fillContainer.mask = cell.fillMask
        cell.fillContainer.backgroundColor = nil
        cell.fillGradient.isHidden = false
        cell.bitmap.isHidden = false
        if cell.bitmap.contents as AnyObject? === TiledBubble.emptyImage as AnyObject { cell.bitmap.contents = nil }
        CATransaction.commit()
        spec = nil; row = nil; layout = nil
    }

    func set(spec: RowSpec, row p: PartRow, layout: LongTextLayout, cell: RowCell) {
        self.spec = spec
        self.row = p
        self.layout = layout
        body = RowDraw.bodyRect(spec)
        let s = Fixture.renderScale
        let full = CGRect(x: 0, y: 0, width: spec.width, height: spec.height + 2 * RowDraw.margin)
        container.frame = full
        let fill = cell.fillContainer
        fill.isHidden = false
        fill.frame = full
        if p.outgoing {
            fill.backgroundColor = nil
            cell.fillGradient.isHidden = false
            cell.fillGradient.frame = CGRect(x: 0, y: -cell.windowY, width: spec.width, height: Fixture.gradientHeight)
        } else {
            cell.fillGradient.isHidden = true
            fill.backgroundColor = Fixture.incoming.cgColor
        }
        let x0 = floor((body.minX - BubbleSlices.pad) * s) / s
        let phase = body.minX - BubbleSlices.pad - x0
        let img = BubbleSlices.image(bodyWidth: body.width, phase: phase, outgoing: p.outgoing, tail: p.tail, scale: s)
        let ih = CGFloat(img.height) / s
        shape.contents = img
        shape.contentsScale = s
        // The middle pixel row stretches (the image is symmetric, so the flip does not matter).
        shape.contentsCenter = CGRect(x: 0, y: 0.5 - 0.5 / CGFloat(img.height), width: 1, height: 1 / CGFloat(img.height))
        shape.frame = CGRect(x: x0, y: body.minY - BubbleSlices.vpad, width: CGFloat(img.width) / s,
                             height: body.height + ih - 2 * BubbleSlices.cap)
        container.contentsScale = s
        configureFold(p, layout: layout, scale: s)
    }

    private func configureFold(_ p: PartRow, layout: LongTextLayout, scale s: CGFloat) {
        folded = LongTextFold.isFolded(p.ref.messageId, layout)
        headClip.isHidden = !folded
        tailClip.isHidden = !folded
        band.isHidden = !folded
        guard folded else { bandRect = .zero; return }
        let lh = Fixture.lineHeight, textTop = body.minY + Fixture.bubblePadY
        let headH = CGFloat(LongTextFold.headLines) * lh, tailH = CGFloat(LongTextFold.tailLines) * lh
        // Clips reach 4 pt past their line slots (descenders), never into the other region's text.
        headClip.frame = CGRect(x: body.minX, y: body.minY, width: body.width, height: textTop + headH + 4 - body.minY)
        let tailTop = textTop + headH + LongTextFold.bandHeight
        tailClip.frame = CGRect(x: body.minX, y: tailTop - 4, width: body.width, height: body.maxY - (tailTop - 4))
        bandRect = CGRect(x: body.minX, y: textTop + headH, width: body.width, height: LongTextFold.bandHeight)
        band.frame = bandRect
        let label = LongTextFold.label(layout.index.hardLines)
        let key = "\(label)|\(p.outgoing)|\(body.width)|\(s)|\(Fixture.paletteGeneration)"
        guard key != bandKey else { return }
        bandKey = key
        let font = UIFont.systemFont(ofSize: Fixture.bodyFont.pointSize, weight: .semibold)
        let color = p.outgoing ? Fixture.outgoingText : UIColor(red: 0.27, green: 0.55, blue: 1, alpha: 1)
        let rule = (p.outgoing ? Fixture.outgoingText : Fixture.incomingText).withAlphaComponent(0.25)
        Reclaimer.release(band.contents)
        band.contentsScale = s
        band.contents = WideBitmap.make(size: bandRect.size, scale: s, opaque: false) { ctx in
            rule.setFill()
            ctx.fill(CGRect(x: Fixture.bubblePadX, y: lh - 0.5, width: 18, height: 1))
            TextDraw.line(label, font: font, color: color, x: Fixture.bubblePadX + 26, baseline: lh + 4.5, in: ctx)
        }
    }

    /// Tiles for the viewport plus one screen each way; measurement 3 screens each way.
    func update(_ cell: RowCell) {
        guard let layout, let row, let sv = cell.superview, layout.index.ready, layout.blockCount > 0 else {
            if layout?.index.ready == false { releaseAll() }
            return
        }
        let vis = sv.bounds
        let f = cell.frame
        let lo = vis.minY - f.minY, hi = vis.maxY - f.minY
        let lh = Fixture.lineHeight
        let textTop = body.minY + Fixture.bubblePadY
        let screen = max(vis.height, 300)
        let total = layout.totalLines
        if !folded {
            func line(_ y: CGFloat) -> Int { Int(floor((y - textTop) / lh)) }
            let wantA = max(0, line(lo - screen)), wantB = min(total, line(hi + screen) + 1)
            guard wantA < wantB else { releaseAll(); return }
            let screenLines = Int(screen / lh)
            layout.require(lines: max(0, wantA - 2 * screenLines)..<min(total, wantB + 2 * screenLines))
        }

        let s = Fixture.renderScale, palette = Fixture.paletteGeneration
        // Segments: text lines shown at a display offset in a parent layer. Full: one. Folded:
        // the first 40 lines, and the last 40 lines moved up under the band (both clipped).
        var segments: [(lines: Range<Int>, shift: CGFloat, parent: CALayer)] = [(0..<total, 0, container)]
        if folded {
            let tailFirst = max(LongTextFold.headLines, total - LongTextFold.tailLines)
            segments = [(0..<min(total, LongTextFold.headLines), 0, headClip),
                        (tailFirst..<total, CGFloat(LongTextFold.headLines - tailFirst) * lh + LongTextFold.bandHeight, tailClip)]
        }
        var wanted: [(TileCache.Key, CGRect, Bool, Int, CALayer)] = []
        let n = TiledBubble.linesPerTile
        for seg in segments where !seg.lines.isEmpty {
            func segLine(_ y: CGFloat) -> Int { Int(floor((y - seg.shift - textTop) / lh)) }
            let visA = max(seg.lines.lowerBound, segLine(lo)), visB = min(seg.lines.upperBound, segLine(hi) + 1)
            let wantA = max(seg.lines.lowerBound, segLine(lo - screen)), wantB = min(seg.lines.upperBound, segLine(hi + screen) + 1)
            guard wantA < wantB else { continue }
            if folded { layout.require(lines: max(0, wantA - 16)..<min(total, wantB + 16)) }
            let origin = seg.parent === container ? CGPoint.zero : seg.parent.frame.origin
            var b = layout.block(containingLine: wantA)
            while b < layout.blockCount {
                let first = layout.firstLine(ofBlock: b), count = layout.lines(ofBlock: b)
                if first >= wantB { break }
                let c0 = max(0, (wantA - first) / n), c1 = max(c0, (min(wantB, first + count) - 1 - first) / n)
                for c in c0...c1 where first + c * n < first + count {
                    let a = first + c * n
                    let k = TileCache.Key(lineage: layout.index.lineage, start: layout.index.starts[b], end: layout.index.starts[b + 1],
                                          final: layout.index.isFinal(b), column: layout.column, chunk: c, outgoing: row.outgoing,
                                          scale: s, palette: palette)
                    let r = CGRect(x: body.minX - origin.x, y: textTop + seg.shift + CGFloat(a) * lh - TiledBubble.overflow - origin.y,
                                   width: body.width, height: CGFloat(n) * lh + 2 * TiledBubble.overflow)
                    wanted.append((k, r, a < visB && a + min(n, count - c * n) > visA, b, seg.parent))
                }
                b += 1
            }
        }
        let wantedKeys = Set(wanted.map(\.0))
        // Tiles that left: back to the pool unless a newer key takes their slot (stale pixels stay until it renders).
        var stale: [TileCache.Slot: CALayer] = [:]
        for (k, l) in live where !wantedKeys.contains(k) {
            live[k] = nil
            stale[k.slot] = l
        }
        for (k, op) in pending where !wantedKeys.contains(k) { op.cancel(); pending[k] = nil; TiledStats.tilesCancelled += 1 }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        var mainTiles = 0
        for (k, r, visible, blk, parent) in wanted {
            if let l = live[k] {
                if l.superlayer !== parent { parent.addSublayer(l) }
                if l.frame != r { l.frame = r }
                continue
            }
            let old = stale.removeValue(forKey: k.slot)
            let l = old ?? take()
            if l.superlayer !== parent { parent.addSublayer(l) }
            l.frame = r
            l.contentsScale = s
            live[k] = l
            if let img = TileCache.shared.get(k) { l.contents = img; continue }
            // Visible and inside the per-frame draw budget (also in transactions: a message
            // that arrives must not cost a frame; the rest arrives from the tile queue).
            // Only when the block's line breaks are known: Core Text measurement never runs on main.
            // At most one tile per frame on main (about 1.5 ms): the rest come from the queue.
            // A slot that still shows its previous pixels (streaming tail, new width) waits for the queue.
            if visible, old?.contents == nil, mainTiles == 0, RowCell.mainDrawBudgetLeft(), let bl = BlockLayoutCache.shared.get(layout.key(blk)) {
                mainTiles += 1
                let t0 = CACurrentMediaTime()
                let img = TiledBubble.render(bl, chunk: k.chunk, outgoing: k.outgoing, width: r.width, scale: s)
                RowCell.mainDrawSpent += CACurrentMediaTime() - t0
                TiledStats.tilesMain += 1
                TileCache.shared.put(k, img)
                l.contents = img
                continue
            }
            if pending[k] == nil { enqueue(k, layout: layout, block: blk, width: r.width, visible: visible) }
        }
        for (_, l) in stale { l.contents = nil; l.isHidden = true; pool.append(l) }
        CATransaction.commit()
        visibleKeys = Set(wanted.filter { $0.2 }.map(\.0))
        TiledStats.blankVisible += lastBlank
        TiledStats.liveTiles = live.count
        TiledStats.maxLiveTiles = max(TiledStats.maxLiveTiles, live.count)
    }

    private func take() -> CALayer {
        if let l = pool.popLast() { l.isHidden = false; return l }
        let l = CALayer()
        l.actions = TiledBody.noActions
        container.addSublayer(l)
        return l
    }

    private func releaseAll() {
        guard !live.isEmpty || !pending.isEmpty else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for (_, l) in live { l.contents = nil; l.isHidden = true; pool.append(l) }
        CATransaction.commit()
        live.removeAll()
        for (_, op) in pending { op.cancel() }
        pending.removeAll()
    }

    private func enqueue(_ k: TileCache.Key, layout: LongTextLayout, block: Int, width: CGFloat, visible: Bool) {
        let op = BlockOperation()
        op.queuePriority = visible ? .veryHigh : .normal
        op.addExecutionBlock { [weak op] in
            guard let op, !op.isCancelled else { return }
            let img = TiledBubble.render(layout.blockLayout(block), chunk: k.chunk, outgoing: k.outgoing, width: width, scale: k.scale)
            DispatchQueue.main.async { [weak self] in
                TiledStats.tilesAsync += 1
                guard k.palette == Fixture.paletteGeneration, k.scale == Fixture.renderScale else { return }
                TileCache.shared.put(k, img)
                guard let self else { return }
                self.pending[k] = nil
                if let l = self.live[k] {
                    CATransaction.begin(); CATransaction.setDisableActions(true)
                    l.contents = img
                    CATransaction.commit()
                }
            }
        }
        pending[k] = op
        TiledBubble.tileQueue.addOperation(op)
    }
}
