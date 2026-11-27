import AppKit
import CmuxNextDesign
import CmuxNextIcons
import QuartzCore

/// Three thin bars at the end of the controls that rise and fall while the
/// track plays, the mark music apps put on what plays. Decorative: Now Playing
/// reports no audio levels. Each bar grows from the view's vertical center, so
/// at any height the bars stay on the controls' one center line (#52939). Each
/// bar loops on its own period as one Core Animation, so the render server
/// runs it and the app takes no wakeups. Paused, under Reduce Motion or with
/// animations off, they rest still at low heights, also when Reduce Motion
/// turns on mid-track; nothing flashes. The card sizes the view's height to
/// the controls' glyph.
final class SidebarNowPlayingLevels: NSView {
    static let width: CGFloat = 13
    static let levelsKey = "levels"
    private static let barWidth: CGFloat = 2.5
    /// Heights at rest, as fractions of the view.
    static let rest: [CGFloat] = [0.4, 0.65, 0.3]
    /// Each bar's heights over one loop, and the loop's length: unequal periods, so the bars never
    /// line up into a visible repeat, and soft highs and lows, so they sway rather than jump.
    private static let loops: [(levels: [CGFloat], period: TimeInterval)] = [
        ([0.4, 0.95, 0.55, 0.85, 0.35, 0.4], 1.6),
        ([0.65, 0.35, 0.9, 0.5, 1.0, 0.65], 1.3),
        ([0.3, 0.75, 0.45, 0.9, 0.5, 0.3], 1.9),
    ]
    private let bars = (0..<3).map { _ in CALayer() }
    private(set) var isPlaying = false
    /// Pins Reduce Motion for these bars only (tests); nil follows `Motion.animatesLoops`.
    var reduceMotionOverride: Bool? { didSet { update() } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for bar in bars {
            // Centered, so a bar grows up and down from the controls' center line.
            bar.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            layer?.addSublayer(bar)
        }
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// The motion observers while the bars are in a window (``observeMotion(_:)``).
    private var motionObservers: [(center: NotificationCenter, token: any NSObjectProtocol)] = []

    /// Reduce Motion (the system's or cmux's own) or the animation speed changed mid-track: the
    /// bars start or still at once. Block observers on the main queue while in a window, removed
    /// when the view leaves it, so the view needs no deinit.
    private func observeMotion(_ on: Bool) {
        guard on != !motionObservers.isEmpty else { return }
        guard on else {
            for observer in motionObservers { observer.center.removeObserver(observer.token) }
            motionObservers = []
            return
        }
        let names: [(NotificationCenter, Notification.Name)] = [
            (NotificationCenter.default, Motion.reduceMotionDidChange),
            (NotificationCenter.default, Motion.speedDidChange),
            (NSWorkspace.shared.notificationCenter, NSWorkspace.accessibilityDisplayOptionsDidChangeNotification),
        ]
        motionObservers = names.map { center, name in
            (center, center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                // main-proof: the observer runs on the main queue (queue: .main)
                MainActor.assumeIsolated { self?.update() }
            })
        }
    }

    func show(playing: Bool) {
        guard playing != isPlaying else { return }
        isPlaying = playing
        update()
    }

    /// The bars' fill, in the theme's secondary text color.
    func applyColors() {
        performWithTheme {
            for bar in bars { bar.backgroundColor = Palette.textSecondary.cgColor }
        }
    }

    /// Whether the bars move now.
    var moves: Bool {
        isPlaying && window != nil && !isHiddenOrHasHiddenAncestor && (reduceMotionOverride.map { !$0 } ?? Motion.indicators.animatesLoops)
    }

    override func layout() {
        super.layout()
        update()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observeMotion(window != nil)
        applyColors()
        update()
    }

    override func viewDidHide() {
        super.viewDidHide()
        update()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        update()
    }

    private func update() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let height = bounds.height, width = Self.barWidth
        let gap = bars.count > 1 ? max(0, (bounds.width - CGFloat(bars.count) * width) / CGFloat(bars.count - 1)) : 0
        let moves = moves
        for (index, bar) in bars.enumerated() {
            bar.removeAnimation(forKey: Self.levelsKey)
            bar.cornerRadius = width / 2 // radius-allow: an equalizer bar, not a button
            bar.bounds = CGRect(x: 0, y: 0, width: width, height: Self.rest[index] * height)
            bar.position = CGPoint(x: CGFloat(index) * (width + gap) + width / 2, y: height / 2)
            guard moves, height > 0 else { continue }
            bar.add(Self.loop(index, height: height), forKey: Self.levelsKey)
        }
    }

    /// One bar's endless rise and fall.
    static func loop(_ index: Int, height: CGFloat) -> CAAnimation {
        let loop = loops[index % loops.count]
        // motion-allow: decorative level bars loop on their own periods while a track plays; Motion.animatesLoops gates them.
        let animation = CAKeyframeAnimation(keyPath: "bounds.size.height")
        animation.values = loop.levels.map { $0 * height }
        animation.keyTimes = loop.levels.indices.map { NSNumber(value: Double($0) / Double(loop.levels.count - 1)) }
        // motion-allow: each step eases in and out, so a bar sways instead of jumping.
        animation.timingFunctions = Array(repeating: CAMediaTimingFunction(name: .easeInEaseOut), count: loop.levels.count - 1)
        animation.duration = loop.period
        animation.repeatCount = .infinity
        return animation
    }
}
