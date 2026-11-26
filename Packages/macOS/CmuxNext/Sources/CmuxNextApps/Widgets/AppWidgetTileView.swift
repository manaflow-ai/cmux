import AppKit
import CmuxNextCompat
import CmuxNextDesign

/// One widget tile: the widget's scene (``AppSceneHostingView``, the sidebar's AppKit scene path) on a
/// rounded card, laid out to fill the tile. Let it crash: while the widget's render throws, the
/// tile keeps its last scene, dimmed, with a quiet "Retrying" line; it never blanks. In edit mode a
/// minus badge removes it and the scene takes no clicks (the area drags the tile instead).
final class AppWidgetTileView: NSView {
    let instance: String
    let mount: AppMount
    let scene: AppSceneHostingView
    private let card = CALayer()
    private let staleHint = ChromeLabel(labelWithString: AppWidgetStrings.retrying)
    let removeBadge = AppWidgetBadgeView()
    private var feed: Task<Void, Never>?
    private var shownStale: String??

    var isEditing = false {
        didSet {
            guard isEditing != oldValue else { return }
            removeBadge.isHidden = !isEditing
            needsLayout = true
        }
    }

    /// Dims the tile while it is lifted in a drag.
    var isLifted = false {
        didSet { if isLifted != oldValue { Motion.sidebar.animate(.fadeIn, in: self, { animator().alphaValue = isLifted ? 0.4 : 1 }) } }
    }

    init(instance: String, mount: AppMount) {
        self.instance = instance
        self.mount = mount
        scene = AppSceneHostingView(model: mount.model, bundleDirectory: mount.bundleDirectory)
        scene.fillsBounds = true
        super.init(frame: .zero)
        wantsLayer = true
        card.cornerCurve = .continuous
        card.masksToBounds = true
        card.actions = ["backgroundColor": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer?.addSublayer(card)
        scene.wantsLayer = true
        scene.layer?.cornerCurve = .continuous
        scene.layer?.masksToBounds = true
        addSubview(scene)
        staleHint.font = Typography.caption
        staleHint.isHidden = true
        addSubview(staleHint)
        removeBadge.isHidden = true
        addSubview(removeBadge)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityIdentifier("cmux.widgets.tile.\(instance)")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    nonisolated override var isFlipped: Bool { true }
    nonisolated override var wantsUpdateLayer: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        feed?.cancel()
        feed = nil
        guard window != nil else { return }
        showStale(mount.model.staleReason)
        // task-owner: this view (cancelled when it leaves its window); event-driven (Observation).
        feed = Task { [weak self, model = mount.model] in
            for await stale in ObservationStream({ model.staleReason }) { self?.showStale(stale) }
        }
    }

    /// The stale look: the last scene dimmed and the retry hint, or the plain tile again.
    private func showStale(_ reason: String?) {
        guard shownStale != .some(reason) else { return }
        shownStale = .some(reason)
        let stale = reason != nil
        staleHint.isHidden = !stale
        // The tooltip is the reason, one line; VoiceOver hears the whole sentence.
        themedToolTip = reason
        setAccessibilityHelp(reason.map(AppWidgetStrings.staleHelp))
        Motion.sidebar.animate(.fadeIn, in: self, { scene.animator().alphaValue = stale ? AppWidgetTileView.staleOpacity : 1 })
        needsLayout = true
    }

    /// How much of a stale tile's scene shows.
    static let staleOpacity: CGFloat = 0.45
    /// Whether the tile shows its stale look (tests).
    var isStale: Bool { !staleHint.isHidden }

    /// The tile's corner radius: Apple's widget corners, nested in the sidebar's surfaces.
    static var cornerRadius: CGFloat { Metrics.surfaceCornerRadius }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        card.frame = bounds
        card.cornerRadius = Self.cornerRadius
        scene.layer?.cornerRadius = Self.cornerRadius
        CATransaction.commit()
        scene.frame = bounds
        let hint = staleHint.naturalSize
        let inset = Metrics.space2
        staleHint.frame = CGRect(x: bounds.maxX - inset - hint.width, y: bounds.maxY - inset - hint.height,
                                 width: hint.width, height: hint.height)
        let side = AppWidgetBadgeView.side
        // Inside the corner, so the whole badge takes the click.
        removeBadge.frame = CGRect(x: Metrics.space1, y: Metrics.space1, width: side, height: side)
    }

    override func updateLayer() {
        performWithTheme {
            card.backgroundColor = Palette.hoverFill.cgColor
            staleHint.textColor = Palette.textSecondary
        }
    }

    /// In edit mode the scene takes no input: a press drags the tile, the badge removes it.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard isEditing else { return super.hitTest(point) }
        let local = convert(point, from: superview)
        if !removeBadge.isHidden, removeBadge.frame.contains(local) { return removeBadge }
        return bounds.contains(local) ? self : nil
    }
}
