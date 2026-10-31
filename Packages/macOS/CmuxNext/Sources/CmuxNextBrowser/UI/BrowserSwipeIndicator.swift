import AppKit
import CmuxNextDesign
import CmuxNextIcons

/// The pill at a page's edge during a Back or Forward swipe: an arrow on the theme accent that
/// slides in from the left edge (Back) or the right edge (Forward) as the fingers move, and is
/// fully in, at full strength, once letting go would navigate. With no page that way it moves a
/// short, dampened distance (AppKit's rubber band) at half strength, and nothing happens.
///
/// A Chromium page is a child window above the window's own views, so the pill draws on the
/// window's overlay host in the `.pane` layer, clipped to the page (as `PageFloatingOverlays`).
@MainActor
final class BrowserSwipeIndicator {
    static let size = CGSize(width: 44, height: 32)
    static let inset: CGFloat = 16
    /// Gesture amount at which the pill is fully in: AppKit ends a swipe past about a third.
    static let fullAmount: CGFloat = 0.3

    private let view = BrowserSwipeIndicatorView(frame: CGRect(origin: .zero, size: size))
    private var handle: OverlayHandle?
    private weak var page: NSView?
    private let direction: BrowserSwipeDirection
    private let available: Bool

    init(page: NSView, direction: BrowserSwipeDirection, available: Bool) {
        self.page = page
        self.direction = direction
        self.available = available
        view.direction = direction
    }

    /// Pure: the pill's frame in `page`'s coordinates (not flipped) at `progress` (0 out, 1 in),
    /// centered vertically.
    static func frame(in bounds: CGRect, direction: BrowserSwipeDirection, progress: CGFloat) -> CGRect {
        let travel = size.width + inset
        let clamped = min(max(progress, 0), 1)
        let x = direction == .back ? bounds.minX - size.width + travel * clamped
            : bounds.maxX - travel * clamped
        return CGRect(x: x, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
    }

    /// Pure: how far in the pill is for AppKit's gesture `amount` (its sign is the direction).
    static func progress(amount: CGFloat) -> CGFloat {
        min(abs(amount) / fullAmount, 1)
    }

    func update(amount: CGFloat) {
        guard let page, let window = page.window else { return dismiss() }
        let progress = Self.progress(amount: amount)
        let local = Self.frame(in: page.bounds, direction: direction, progress: progress)
        let anchor = page.convert(local, to: nil)
        let clip = page.convert(page.bounds, to: nil)
        view.alphaValue = available ? (progress >= 1 ? 1 : 0.75) : 0.5
        view.isArmed = available && progress >= 1
        if let handle, !handle.isDismissed, view.window?.parent === window {
            handle.update(paneClip: clip)
            handle.update(anchor: anchor)
            return
        }
        handle?.dismiss()
        page.themeScope.fullStrength.root(view)
        handle = WindowOverlayHost.host(for: window).present(
            view, options: OverlayOptions(kind: .attached, anchor: anchor, passesThroughClicks: true, layer: .pane(clip: clip))
        )
    }

    func dismiss() {
        handle?.dismiss()
        handle = nil
    }
}

/// The pill itself: an accent capsule with a white arrow.
final class BrowserSwipeIndicatorView: NSView {
    var direction: BrowserSwipeDirection = .back {
        didSet { updateArrow() }
    }
    /// Letting go navigates: the arrow grows a little.
    var isArmed = false {
        didSet { if isArmed != oldValue { updateArrow() } }
    }
    private let arrow = NSImageView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = frame.height / 2
        layer?.cornerCurve = .continuous
        arrow.frame = bounds
        arrow.autoresizingMask = [.width, .height]
        arrow.imageScaling = .scaleNone
        addSubview(arrow)
        updateArrow()
        updateColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        updateColors()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    private func updateColors() {
        performWithTheme {
            layer?.backgroundColor = Palette.accentFill.cgColor
            arrow.contentTintColor = Palette.onAccent
        }
    }

    /// Chrome's toolbar Back or Forward arrow, a template tinted `onAccent`. Its path spans about
    /// 60% of the icon box, so 22 and 24 pt draw it about as large as the 14 and 16 pt SF arrows did.
    private func updateArrow() {
        let name: IconName = direction == .back ? .browserToolbarBack : .browserToolbarForward
        arrow.image = NSImage.icon(name, size: isArmed ? 24 : 22)
    }
}
