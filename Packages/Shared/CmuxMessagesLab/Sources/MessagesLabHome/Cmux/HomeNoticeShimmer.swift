import AppKit

/// The Chief's status line's shimmer ("Running · 4s" with a light band sweeping its text, as Claude's and
/// ChatGPT's "Thinking…").
///
/// User 2026-10-30 5:03 PM: "i don't like this ui… make it just one line with shimmer text" (over a lone
/// "›" row, "Running · 4s" and the typing bubble). `RowDraw` draws the line in the message text color;
/// this is its row bitmap's mask: ``restAlpha`` everywhere (the caption grey), and ``band``, a soft
/// opaque stripe, sweeping left to right over the text. The sweep is one repeating Core Animation group
/// on the band (render server): no timer, no redraw, no main-thread work per frame. The per-second text
/// change ("4s" → "5s") keeps the sweep running where it was; it starts over only when the line's width
/// moves to another ``travelStep`` bucket, and then from the same begin time, so its phase holds.
/// Under Reduce Motion or with Home animations off (`MessagesLabHomeView.holdsTypingStill`) the band is
/// hidden and nothing loops (cx-sya4n).
///
/// Not `@MainActor`: the vendored `RowCell` that owns it builds with Swift 5 minimal concurrency and is
/// not main-actor isolated; like the cell's own layers, it is used only on the main thread (configure,
/// decorate, Reduce Motion changes).
final class HomeNoticeShimmer {
    /// The animation's key on ``band``.
    static let animationKey = "shimmer"
    /// The band's width, points.
    static let bandWidth: CGFloat = 56
    /// The sweep's speed, points per second.
    static let speed: CGFloat = 170
    /// The pause after each sweep, seconds.
    static let pause: CFTimeInterval = 0.45
    /// Line widths share a sweep within this many points (a new second's digits do not restart it).
    static let travelStep: CGFloat = 48

    /// The mask's alpha off the band: the line's text color at this alpha reads as the caption grey
    /// (`Fixture.secondaryText`) over the transcript.
    static var restAlpha: CGFloat { Fixture.lightAppearance ? 0.55 : 0.64 }

    /// The row bitmap's mask (in the bitmap's coordinates).
    let mask = CALayer()
    /// The light band that sweeps the line (a sublayer of ``mask``).
    let band = CAGradientLayer()
    /// The sweep's distance the running animation was made for (nil: none running).
    private var travel: CGFloat?
    /// The first sweep's begin (layer time), kept so a new sweep keeps the phase.
    private var begin: CFTimeInterval?

    init() {
        let none: [String: CAAction] = ["position": NSNull(), "bounds": NSNull(), "frame": NSNull(), "hidden": NSNull(),
                                        "backgroundColor": NSNull(), "contentsScale": NSNull()]
        mask.actions = none
        band.actions = none
        band.startPoint = CGPoint(x: 0, y: 0.5)
        band.endPoint = CGPoint(x: 1, y: 0.5)
        band.colors = [NSColor(white: 1, alpha: 0).cgColor, NSColor(white: 1, alpha: 1).cgColor, NSColor(white: 1, alpha: 0).cgColor]
        band.locations = [0, 0.5, 1]
        mask.addSublayer(band)
    }

    /// Whether the band sweeps now.
    var isRunning: Bool { band.animation(forKey: Self.animationKey) != nil }

    /// Shows the shimmer over `cell`'s notice row `spec` (any other row: `detach(from:)`).
    static func configure(_ cell: RowCell, _ spec: RowSpec) {
        guard case let .notice(text) = spec.kind else { return }
        let shimmer = cell.noticeShimmer ?? HomeNoticeShimmer()
        cell.noticeShimmer = shimmer
        let span = RowDraw.drawSpan(spec)
        let size = CGSize(width: span.upperBound - span.lowerBound, height: spec.height + 2 * RowDraw.margin)
        let room = max(spec.metrics.receiptRight - RowDraw.noticeLeft, 0)
        shimmer.place(in: size, textLeft: RowDraw.noticeLeft - span.lowerBound, textWidth: min(HomeNoticeRows.width(text), room))
        if cell.bitmap.mask !== shimmer.mask { cell.bitmap.mask = shimmer.mask }
    }

    /// Sizes the mask to the bitmap (`size`) and the band's track to the text, and starts, keeps or
    /// stops the sweep.
    func place(in size: CGSize, textLeft: CGFloat, textWidth: CGFloat) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        mask.frame = CGRect(origin: .zero, size: size)
        mask.backgroundColor = NSColor(white: 1, alpha: Self.restAlpha).cgColor
        band.frame = CGRect(x: textLeft - Self.bandWidth, y: 0, width: Self.bandWidth, height: size.height)
        refresh(textWidth: textWidth)
    }

    /// Runs the sweep over `textWidth` (nil: the width it runs for now), unless motion holds still.
    func refresh(textWidth: CGFloat? = nil) {
        if MessagesLabHomeView.holdsTypingStill {
            stop()
            return
        }
        if let textWidth { lastTextWidth = textWidth }
        let width = Self.travel(for: lastTextWidth)
        band.isHidden = false
        guard width != travel || !isRunning else { return }
        travel = width
        let sweep = CABasicAnimation(keyPath: "transform.translation.x")
        sweep.fromValue = 0
        sweep.toValue = width
        sweep.duration = CFTimeInterval(width / Self.speed)
        sweep.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        let group = CAAnimationGroup()
        group.animations = [sweep]
        group.duration = sweep.duration + Self.pause
        group.repeatCount = .infinity
        group.isRemovedOnCompletion = false
        let start = begin ?? band.convertTime(CACurrentMediaTime(), from: nil)
        begin = start
        group.beginTime = start
        band.add(group, forKey: Self.animationKey)
    }

    /// The line's width the band last swept (or holds for, while still).
    private var lastTextWidth: CGFloat = 0

    /// The band's distance for a line `textWidth` wide: past its end, in ``travelStep`` buckets.
    static func travel(for textWidth: CGFloat) -> CGFloat {
        ((textWidth + bandWidth) / travelStep).rounded(.up) * travelStep
    }

    /// Stops the sweep and hides the band (the line stays at ``restAlpha``).
    func stop() {
        band.removeAnimation(forKey: Self.animationKey)
        band.isHidden = true
        travel = nil
        begin = nil
    }

    /// Takes the mask off `cell`'s bitmap (another row now) and stops.
    func detach(from cell: RowCell) {
        if cell.bitmap.mask === mask { cell.bitmap.mask = nil }
        stop()
    }
}
