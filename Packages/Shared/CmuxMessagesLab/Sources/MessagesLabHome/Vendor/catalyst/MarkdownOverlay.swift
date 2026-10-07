#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// Horizontal scrolling and copy buttons of markdown blocks inside a row cell.
/// A scrollable block (code wider than the bubble, a table wider than its column
/// minimums) is not in the row bitmap: it is a clip layer over the bitmap with
/// one content bitmap of the block's full width (rendered off main). Scrolling moves
/// the content layer (no drawing; 0 ms per frame). Edge fades show that more
/// content is there. Code blocks get a copy button, shown on hover.
final class MarkdownOverlay {
    /// Hosts that install overlays (appkit-native, catalyst) set this at launch;
    /// headless renders (evidence, tests) draw every block into the bitmap.
    static var active = false
    static func usesOverlay(_ r: MDRegion) -> Bool { active && r.scrollable }

    final class RegionLayers {
        let clip = CALayer()
        let content = CALayer()
        let fade = CAGradientLayer()
        let indicator = CALayer()
        /// Incoming rows: opaque bubble grey under the clip (the edge fades must not show the
        /// bitmap's unscrolled copy of the block).
        let cover = CALayer()
        var index: Int
        var rendered = false
        init(_ i: Int) { index = i }
    }
    private(set) var layout: MarkdownLayout?
    private(set) var outgoing = false
    private(set) var regions: [RegionLayers] = []
    let copyButton = CALayer()
    let copyGlyph = CATextLayer()
    private(set) var hoverRegion: Int?
    weak var host: CALayer?
    /// Body origin in the host layer's coordinates.
    private(set) var bodyOrigin = CGPoint.zero
    private var generation = 0

    init() {
        copyButton.isHidden = true
        copyButton.cornerRadius = 5
        copyButton.addSublayer(copyGlyph)
        copyGlyph.alignmentMode = .center
        copyGlyph.fontSize = 10
        copyGlyph.contentsScale = Fixture.renderScale
    }

    /// RowCell.configure: install or update the overlay for a part row.
    static func configure(_ cell: RowCell, _ spec: RowSpec) {
        guard active else { return }
        guard case let .part(p) = spec.kind, let md = p.markdown else {
            cell.markdownOverlay?.detach(); return
        }
        let o = cell.markdownOverlay ?? MarkdownOverlay()
        cell.markdownOverlay = o
        // The overlays are siblings above the row bitmap (a mask on the bitmap would hide sublayers).
        let body = RowDraw.bodyRect(spec)
        let host = cell.bitmap.superlayer ?? cell.contentView.layer
        o.bitmap = cell.bitmap
        o.attach(to: host, layout: md, outgoing: p.outgoing, bodyOrigin: CGPoint(x: body.minX, y: body.minY))
    }

    /// Hides the row bitmap under the overlays (the bitmap draws every block at offset 0).
    private let bitmapMask = CAShapeLayer()
    /// The row bitmap: outgoing rows mask it under the overlays (their fill is a layer below it);
    /// incoming rows draw their fill into it, so the overlay clips are opaque bubble grey instead.
    weak var bitmap: CALayer?

    func detach() {
        if bitmap?.mask === bitmapMask { bitmap?.mask = nil }
        for r in regions { r.clip.removeFromSuperlayer(); r.cover.removeFromSuperlayer() }
        regions = []
        copyButton.removeFromSuperlayer()
        layout = nil
        hoverRegion = nil
        generation += 1
    }

    func attach(to host: CALayer, layout md: MarkdownLayout, outgoing: Bool, bodyOrigin: CGPoint) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let same = layout === md && self.outgoing == outgoing && self.host === host
        self.host = host
        self.bodyOrigin = bodyOrigin
        if !same {
            detach()
            layout = md
            self.outgoing = outgoing
            for (i, reg) in md.regions.enumerated() where MarkdownOverlay.usesOverlay(reg) {
                let r = RegionLayers(i)
                r.clip.masksToBounds = true
                r.clip.zPosition = 1
                if !outgoing {
                    r.cover.backgroundColor = Fixture.incoming.cgColor
                    r.cover.cornerRadius = r.clip.cornerRadius
                    r.cover.zPosition = 1
                    host.addSublayer(r.cover)
                }
                r.clip.cornerRadius = reg.kind == .code ? 6 : 0
                r.clip.addSublayer(r.content)
                r.clip.addSublayer(r.indicator)
                r.indicator.cornerRadius = 1.25
                r.indicator.backgroundColor = MDPalette.make(outgoing: outgoing).text.withAlphaComponent(0.32).cgColor
                r.fade.startPoint = CGPoint(x: 0, y: 0.5); r.fade.endPoint = CGPoint(x: 1, y: 0.5)
                r.content.contentsScale = Fixture.renderScale
                host.addSublayer(r.clip)
                regions.append(r)
                render(r, md, outgoing)
            }
            host.addSublayer(copyButton)
        }
        for r in regions { place(r) }
        if let b = bitmap {
            if regions.isEmpty || !outgoing {
                if b.mask === bitmapMask { b.mask = nil }
            } else {
                let path = CGMutablePath()
                path.addRect(CGRect(x: -2000, y: -2000, width: b.bounds.width + 4000, height: b.bounds.height + 4000))
                for r in regions { path.addRect(r.clip.frame.offsetBy(dx: -b.frame.minX, dy: -b.frame.minY)) }
                bitmapMask.fillRule = .evenOdd
                bitmapMask.frame = b.bounds
                bitmapMask.path = path
                b.mask = bitmapMask
            }
        }
        placeCopy()
    }

    private func render(_ r: RegionLayers, _ md: MarkdownLayout, _ outgoing: Bool) {
        let reg = md.regions[r.index]
        let size = CGSize(width: reg.contentWidth, height: reg.frame.height)
        let gen = generation
        let idx = r.index
        MarkdownOverlay.queue.async { [weak self, weak r] in
            let img = WideBitmap.make(size: size, scale: Fixture.renderScale, opaque: false) { ctx in
                MarkdownDraw.draw(ctx, md, body: CGRect(origin: .zero, size: md.size), outgoing: outgoing, mode: .region(idx))
            }
            DispatchQueue.main.async {
                guard let self, let r, self.generation == gen else { return }
                CATransaction.begin(); CATransaction.setDisableActions(true)
                r.content.contents = img
                r.rendered = true
                CATransaction.commit()
            }
        }
    }
    static let queue = DispatchQueue(label: "messages.markdown.overlay", qos: .userInitiated)

    private func place(_ r: RegionLayers) {
        guard let md = layout else { return }
        let reg = md.regions[r.index]
        let off = min(reg.maxOffset, max(0, MarkdownScroll.offset(identity: md.identity, region: r.index)))
        r.clip.frame = reg.frame.offsetBy(dx: bodyOrigin.x, dy: bodyOrigin.y)
        r.cover.frame = r.clip.frame
        r.content.frame = CGRect(x: -off, y: 0, width: reg.contentWidth, height: reg.frame.height)
        // Edge fades: left when scrolled, right when more content follows.
        let w = reg.frame.width
        let edge = min(0.2, 18 / max(1, w))
        r.fade.frame = r.clip.bounds
        let l = off > 0.5, rr = off < reg.maxOffset - 0.5
        r.fade.colors = [UIColor(white: 0, alpha: l ? 0 : 1).cgColor, UIColor.black.cgColor, UIColor.black.cgColor, UIColor(white: 0, alpha: rr ? 0 : 1).cgColor]
        r.fade.locations = [0, NSNumber(value: Double(edge)), NSNumber(value: Double(1 - edge)), 1]
        r.clip.mask = (l || rr) ? r.fade : nil
        // The same indicator MarkdownDraw draws in static renders.
        let track = CGRect(x: 6, y: 0, width: w - 12, height: reg.frame.height)
        let tw = max(18, track.width * w / reg.contentWidth)
        r.indicator.frame = CGRect(x: track.minX + (track.width - tw) * (reg.maxOffset > 0 ? off / reg.maxOffset : 0),
                                   y: reg.frame.height - 4, width: tw, height: 2.5)
    }

    /// Scrolls region `i` by `dx` points. Returns whether it moved (a block at its end
    /// passes the gesture on).
    @discardableResult
    func scroll(region i: Int, by dx: CGFloat) -> Bool {
        guard let md = layout, i < md.regions.count else { return false }
        let reg = md.regions[i]
        let old = MarkdownScroll.offset(identity: md.identity, region: i)
        let new = min(reg.maxOffset, max(0, old + dx))
        guard abs(new - old) > 0.01 else { return false }
        MarkdownScroll.set(identity: md.identity, region: i, new)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for r in regions where r.index == i { place(r) }
        CATransaction.commit()
        return true
    }

    // MARK: Copy button

    /// Hover at a body-local point: shows the copy button of the code block under it.
    func hover(_ p: CGPoint?) {
        guard let md = layout else { return }
        var idx: Int?
        if let p { idx = md.regions.firstIndex { $0.kind == .code && $0.frame.contains(p) } }
        guard idx != hoverRegion else { return }
        hoverRegion = idx
        if idx == nil { copiedRegion = nil }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        placeCopy()
        CATransaction.commit()
    }

    static let copyTitle = String(localized: "markdown.copy", defaultValue: "Copy")
    static let copiedTitle = String(localized: "markdown.copied", defaultValue: "Copied")

    func copyRect(_ i: Int) -> CGRect? {
        guard let md = layout, i < md.regions.count else { return nil }
        let f = md.regions[i].frame
        let w = max(40, (MarkdownOverlay.copyTitle as NSString).size(withAttributes: [.font: UIFont.systemFont(ofSize: 10, weight: .medium)]).width + 14)
        return CGRect(x: f.maxX - w - 4, y: f.minY + 4, width: w, height: 18)
    }

    private func placeCopy() {
        guard let i = hoverRegion, let r = copyRect(i) else { copyButton.isHidden = true; return }
        let pal = MDPalette.make(outgoing: outgoing)
        copyButton.isHidden = false
        copyButton.frame = r.offsetBy(dx: bodyOrigin.x, dy: bodyOrigin.y)
        copyButton.backgroundColor = (outgoing ? UIColor(white: 0, alpha: 0.32) : UIColor(white: 0.5, alpha: 0.35)).cgColor
        copyButton.zPosition = 2
        copyGlyph.string = copiedRegion == i ? MarkdownOverlay.copiedTitle : MarkdownOverlay.copyTitle
        copyGlyph.font = UIFont.systemFont(ofSize: 10, weight: .medium)
        copyGlyph.foregroundColor = pal.text.cgColor
        copyGlyph.frame = CGRect(x: 0, y: 2.5, width: r.width, height: 14)
    }
    private var copiedRegion: Int?

    /// A click at a body-local point on a copy button: the code to copy.
    func copyHit(_ p: CGPoint) -> String? {
        guard let i = hoverRegion, let r = copyRect(i), r.insetBy(dx: -2, dy: -2).contains(p), let md = layout else { return nil }
        copiedRegion = i
        CATransaction.begin(); CATransaction.setDisableActions(true); placeCopy(); CATransaction.commit()
        return md.regions[i].copyText
    }
}
