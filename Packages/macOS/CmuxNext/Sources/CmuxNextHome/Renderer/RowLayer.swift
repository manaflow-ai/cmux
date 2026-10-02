import AppKit
import CmuxNextDesign
import QuartzCore

/// One recycled transcript row: its bitmap as `contents`, or a plain shape
/// (placeholder) for a frame while the bitmap is drawn in the background.
/// The typing row adds three pulsing dots.
final class RowLayer: CALayer {
    private(set) var row: TranscriptRow?
    private(set) var rasterKey: RasterKey?
    private(set) var isPlaceholder = false
    let motionTag = MotionTag()
    private var shape: CALayer?
    private var dots: [CALayer] = []

    nonisolated override init() { super.init() }

    nonisolated override init(layer: Any) { super.init(layer: layer) }

    nonisolated required init?(coder: NSCoder) { nil }

    /// A layer ready for the transcript (no implicit animations).
    static func make() -> RowLayer {
        let layer = RowLayer()
        layer.actions = noActions
        layer.contentsGravity = .resize
        return layer
    }

    static let noActions: [String: any CAAction] = [
        "position": NSNull(), "bounds": NSNull(), "frame": NSNull(), "opacity": NSNull(), "contents": NSNull(),
        "hidden": NSNull(), "backgroundColor": NSNull(), "sublayers": NSNull(), "transform": NSNull(),
        "onOrderIn": NSNull(), "onOrderOut": NSNull(), "cornerRadius": NSNull(), "contentsScale": NSNull(),
    ]

    /// Shows `image` for `row`.
    func show(_ image: CGImage, row: TranscriptRow, key: RasterKey, geometry: TranscriptGeometry) {
        self.row = row
        rasterKey = key
        isPlaceholder = false
        shape?.isHidden = true
        contents = image
        contentsScale = key.scale
        updateDots(row, geometry: geometry, colors: key.colors)
    }

    /// Shows the row's plain shape until its bitmap arrives.
    func showPlaceholder(row: TranscriptRow, key: RasterKey, pad: CGFloat, geometry g: TranscriptGeometry) {
        self.row = row
        rasterKey = key
        isPlaceholder = true
        contents = nil
        guard row.isBubbleLike else {
            shape?.isHidden = true
            return
        }
        let layer = shape ?? {
            let made = CALayer()
            made.actions = RowLayer.noActions
            addSublayer(made)
            shape = made
            return made
        }()
        layer.isHidden = false
        layer.frame = CGRect(x: pad, y: pad, width: row.width, height: row.height)
        layer.cornerRadius = min(g.bubbleRadius, row.height / 2)
        let fill = row.isOutgoing ? key.colors.outgoingFill : key.colors.incomingFill
        layer.backgroundColor = fill.cgColor
    }

    /// The typing row's dots, pulsing while loops may animate.
    func updateDots(_ row: TranscriptRow, geometry: TranscriptGeometry?, colors: TranscriptColors) {
        guard case .typing = row.kind, let g = geometry else {
            if case .typing = row.kind { return }
            dots.forEach { $0.removeFromSuperlayer() }
            dots.removeAll()
            return
        }
        if dots.isEmpty {
            dots = (0..<3).map { _ in
                let dot = CALayer()
                dot.actions = RowLayer.noActions
                addSublayer(dot)
                return dot
            }
        }
        let pad = RowPainter.pad(g)
        let d = (g.lineHeight * 0.38).rounded()
        let gap = d * 0.6
        let total = 3 * d + 2 * gap
        let x0 = pad + (row.width - total) / 2
        // y-up layer: the bubble body spans pad...pad+height
        let y = pad + (row.height - d) / 2
        for (i, dot) in dots.enumerated() {
            dot.frame = CGRect(x: x0 + CGFloat(i) * (d + gap), y: y, width: d, height: d)
            dot.cornerRadius = d / 2
            dot.backgroundColor = colors.textTertiary.cgColor
            TypingPulse.apply(to: dot, index: i)
        }
    }

    /// Recycling: forget the row and every animation.
    func reset() {
        row = nil
        rasterKey = nil
        isPlaceholder = false
        contents = nil
        removeAllAnimations()
        motionTag.ids.removeAll()
        dots.forEach { $0.removeFromSuperlayer() }
        dots.removeAll()
        shape?.isHidden = true
        opacity = 1
    }
}
