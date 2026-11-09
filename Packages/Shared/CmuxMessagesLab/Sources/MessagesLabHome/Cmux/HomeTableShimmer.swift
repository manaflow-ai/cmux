import AppKit
import QuartzCore

/// cmux: the shimmer over a table card's loading pictures (the user, 2026-11-05: "should have better loading
/// skeleton state"). The row bitmap draws each loading picture's skeleton at the picture's own size
/// (``HomeCardDraw/skeleton(_:_:)``); this lays a soft light band over it that sweeps across while it loads,
/// in the visible rows only, and fades it out when the picture arrives, so the picture fades in. With Reduce
/// Motion on the band holds still (no sweep) and still fades.
@MainActor
final class HomeTableShimmer {
    weak var controller: ChatController?
    /// Whether Reduce Motion is on (tests pass a fixed answer).
    var reduceMotion: () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    private var layers: [String: CALayer] = [:]

    /// The sweep's period, in seconds.
    static let period: CFTimeInterval = 1.4
    /// The fade when a picture arrives.
    static let fade: CFTimeInterval = 0.22

    /// Puts a shimmer on every loading picture of the visible table cards; a picture that arrived, or a row
    /// that left the screen, loses its own.
    func place() {
        guard let demo = controller?.demo else { return }
        var wanted: [String: (cell: RowCell, rect: CGRect)] = [:]
        for case let cell as RowCell in demo.collection.visibleCells where !cell.isHidden {
            guard let spec = cell.spec, case let .part(p) = spec.kind, case let .custom(custom) = p.part,
                  custom.kind == HomeTableRowProvider.kind, let payload = HomeTableRowProvider.payload(custom),
                  !(payload.table.loading ?? [:]).isEmpty else { continue }
            let body = RowDraw.bodyRect(spec).offsetBy(dx: cell.rowSnap.x, dy: cell.rowSnap.y)
            let grid = HomeTableGrid(payload.table, available: body.width)
            for slot in grid.pictureRects(at: body.origin) where slot.loading {
                wanted.updateValue((cell, slot.rect), forKey: "\(p.ref.messageId):\(p.ref.partIndex):\(slot.source)") // crash program: dictionary write
            }
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        for (key, layer) in layers where wanted[key] == nil {
            layers.removeValue(forKey: key)
            fadeOut(layer)
        }
        let still = reduceMotion()
        let scale = demo.renderScale
        for (key, want) in wanted {
            let layer = layers[key] ?? Self.make()
            layers.updateValue(layer, forKey: key) // crash program: dictionary write
            if layer.superlayer !== want.cell.layer { want.cell.layer.addSublayer(layer) }
            layer.frame = want.rect
            layer.contentsScale = scale
            demo.scope { Self.paint(layer) }
            layer.sublayers?.first?.frame = CGRect(origin: .zero, size: want.rect.size)
            if let band = layer.sublayers?.last as? CAGradientLayer {
                band.frame = CGRect(x: -want.rect.width, y: 0, width: want.rect.width * 3, height: want.rect.height)
                band.contentsScale = scale
                if still {
                    band.removeAllAnimations()
                } else if band.animation(forKey: "sweep") == nil {
                    band.add(Self.sweep(width: want.rect.width), forKey: "sweep")
                }
            }
        }
    }

    /// Whether a shimmer shows on a loading picture (tests).
    var count: Int { layers.count }

    /// A skeleton block (the card's own fill under the bitmap's skeleton colour) with the light band in it.
    private static func make() -> CALayer {
        let block = CALayer()
        block.cornerRadius = 8
        block.masksToBounds = true
        block.addSublayer(CALayer())
        let band = CAGradientLayer()
        band.locations = [0.35, 0.5, 0.65]
        band.startPoint = CGPoint(x: 0, y: 0.5)
        band.endPoint = CGPoint(x: 1, y: 0.5)
        block.addSublayer(band)
        paint(block)
        return block
    }

    /// Colours `block` for the theme now: every place, so a theme switch (the card bitmap redraws in the new
    /// theme) never leaves a block in the old one's colours.
    private static func paint(_ block: CALayer) {
        block.backgroundColor = Fixture.incoming.cgColor
        block.sublayers?.first?.backgroundColor = HomeCardDraw.skeletonFill
        let light = NSColor.white.withAlphaComponent(Fixture.lightAppearance ? 0.55 : 0.10).cgColor
        (block.sublayers?.last as? CAGradientLayer)?.colors = [NSColor.white.withAlphaComponent(0).cgColor, light,
                                                               NSColor.white.withAlphaComponent(0).cgColor]
    }

    /// The band sweeping once across a block `width` wide, forever.
    private static func sweep(width: CGFloat) -> CABasicAnimation {
        let a = CABasicAnimation(keyPath: "transform.translation.x")
        a.fromValue = -width
        a.toValue = width
        a.duration = period
        a.repeatCount = .infinity
        a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        return a
    }

    /// The picture arrived (or its row left): the block fades away over it.
    private func fadeOut(_ layer: CALayer) {
        guard layer.superlayer != nil else { return }
        CATransaction.begin()
        CATransaction.setAnimationDuration(Self.fade)
        CATransaction.setCompletionBlock { layer.removeFromSuperlayer() }
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = 1
        a.toValue = 0
        a.duration = Self.fade
        a.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(a, forKey: "fade")
        layer.opacity = 0
        CATransaction.commit()
    }
}
