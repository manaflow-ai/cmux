public import AppKit
import CmuxNextWakeups

/// Placing a background by hand (backgrounds plan phase 6): over the window, with its content
/// faded so the art shows, a drag moves the picture, scrolling or pinching zooms it, Reset goes
/// back to the automatic framing and Done (or Escape, or Return) ends. The arrow keys nudge it
/// (Shift: further), + and - zoom, 0 resets. Each change is saved in ``BackdropPlacementStore``
/// at once, so every window showing the picture follows. One overlay at a time, app-wide; it
/// ends by itself when its window shows another background.
@MainActor
public final class BackdropAdjustOverlay: NSView {
    private let backdrop: WindowMaterialView
    private let id: String
    private let imageSize: CGSize
    private var placement: BackdropUserPlacement
    private var lastDrag: NSPoint?
    /// The window's content views this faded, and their opacity before.
    private var faded: [(NSView, CGFloat)] = []
    /// Fades views the window adds while placing (a page, a toast): AppKit sends no change for
    /// `subviews`, so each window update (after every event it handles) looks for new ones.
    private var updateObserver: NSObjectProtocol?
    /// The one overlay placing now, in any window.
    private static weak var active: BackdropAdjustOverlay?
    private let bar = NSVisualEffectView()

    /// The content fades to this while placing, so the art shows through.
    static let fadedContentAlpha: CGFloat = 0.12

    /// Starts placing the picture `window` shows; false when it shows none it can place (no
    /// picture, a video). A second call while placing keeps the first.
    @discardableResult
    public static func begin(in window: NSWindow?) -> Bool {
        guard let window, let content = window.contentView, let backdrop = WindowMaterialView.backdrop(of: window),
              let adjustable = backdrop.adjustable else { return false }
        if let active, active.window === window, active.id == adjustable.id { return true }
        active?.done()
        let overlay = BackdropAdjustOverlay(backdrop: backdrop, id: adjustable.id, imageSize: adjustable.imageSize,
                                            placement: adjustable.current, frame: content.bounds)
        for view in content.subviews where view !== backdrop { overlay.fade(view) }
        content.addSubview(overlay, positioned: .above, relativeTo: nil)
        overlay.updateObserver = NotificationCenter.default.addObserver(forName: NSWindow.didUpdateNotification, object: window,
                                                                        queue: .main) { [weak overlay] _ in
            MainActor.assumeIsolated { overlay?.fadeAdded() } // main-proof: observer on queue: .main
        }
        // Brought forward: from a separate Settings window, the keys and pointer come here.
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(overlay)
        active = overlay
        return true
    }

    private func fade(_ view: NSView) {
        guard view !== self, view !== backdrop, !faded.contains(where: { $0.0 === view }) else { return }
        faded.append((view, view.alphaValue))
        view.alphaValue = Self.fadedContentAlpha
    }

    /// Fades the window's views that came in since.
    private func fadeAdded() {
        guard let content = superview else { return }
        for view in content.subviews { fade(view) }
    }

    /// The overlay `window` shows, if it is placing (tests).
    public static func current(in window: NSWindow?) -> BackdropAdjustOverlay? {
        window?.contentView?.subviews.lazy.compactMap { $0 as? BackdropAdjustOverlay }.first
    }

    init(backdrop: WindowMaterialView, id: String, imageSize: CGSize, placement: BackdropUserPlacement, frame: NSRect) {
        self.backdrop = backdrop
        self.id = id
        self.imageSize = imageSize
        self.placement = placement
        super.init(frame: frame)
        autoresizingMask = [.width, .height]
        setAccessibilityRole(.group)
        setAccessibilityLabel(Self.hint)
        bar.material = .hudWindow
        bar.state = .active
        bar.wantsLayer = true
        bar.layer?.cornerRadius = 12
        let hint = ThemedLabel(labelWithString: Self.hint)
        let reset = ThemedBezelButton(title: Self.resetTitle, target: self, action: #selector(reset))
        let done = ThemedBezelButton(title: Self.doneTitle, target: self, action: #selector(done))
        done.keyEquivalent = "\r"
        let row = NSStackView(views: [hint, reset, done])
        row.spacing = 12
        row.edgeInsets = NSEdgeInsets(top: 10, left: 16, bottom: 10, right: 12)
        row.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(row)
        bar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bar)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: bar.leadingAnchor), row.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            row.topAnchor.constraint(equalTo: bar.topAnchor), row.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
            bar.centerXAnchor.constraint(equalTo: centerXAnchor), bar.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -24),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override public var acceptsFirstResponder: Bool { true }

    /// The picture's size on screen at the current zoom.
    private var shownSize: CGSize {
        let view = backdrop.bounds.size
        guard imageSize.width > 0, imageSize.height > 0 else { return .zero }
        let scale = max(view.width / imageSize.width, view.height / imageSize.height) * placement.zoom
        return CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
    }

    /// Moves the picture by `dx`, `dy` points (y up), as a drag does. The center stays where the
    /// picture still covers the window, so a drag past an edge has no dead travel to undo.
    public func move(dx: CGFloat, dy: CGFloat) {
        let size = shownSize, view = backdrop.bounds.size
        guard size.width > 0, size.height > 0 else { return }
        // The picture follows the pointer: the point at the center moves the other way.
        let middleX = backdrop.visibleMiddle, middleY = view.height / 2
        // Covering keeps the image's origin in [view - size, 0], so the center point lies in
        // [middle / size, (middle - view + size) / size].
        let x = min(max(placement.centerX - dx / size.width, middleX / size.width), (middleX - view.width + size.width) / size.width)
        let y = min(max(placement.centerY + dy / size.height, middleY / size.height), (middleY - view.height + size.height) / size.height)
        save(BackdropUserPlacement(centerX: x, centerY: y, zoom: placement.zoom))
    }

    /// Zooms by `factor` (above 1 closer), as a pinch or a scroll does.
    public func zoom(by factor: CGFloat) {
        guard factor.isFinite, factor > 0 else { return }
        save(BackdropUserPlacement(centerX: placement.centerX, centerY: placement.centerY, zoom: placement.zoom * factor))
    }

    private func save(_ new: BackdropUserPlacement) {
        // The window shows another background now: nothing of this one to save.
        guard backdrop.adjustable?.id == id else { return done() }
        placement = new
        backdrop.placements.set(new, for: id)
    }

    override public func keyDown(with event: NSEvent) {
        let step: CGFloat = event.modifierFlags.contains(.shift) ? 50 : 10
        switch event.specialKey {
        case .leftArrow?: move(dx: -step, dy: 0)
        case .rightArrow?: move(dx: step, dy: 0)
        case .upArrow?: move(dx: 0, dy: step)
        case .downArrow?: move(dx: 0, dy: -step)
        default:
            switch event.charactersIgnoringModifiers {
            case "+", "=": zoom(by: 1.1)
            case "-", "_": zoom(by: 1 / 1.1)
            case "0": reset()
            default: super.keyDown(with: event)
            }
        }
    }

    override public func mouseDown(with event: NSEvent) { lastDrag = event.locationInWindow }

    override public func mouseDragged(with event: NSEvent) {
        let point = event.locationInWindow
        defer { lastDrag = point }
        guard let last = lastDrag else { return }
        move(dx: point.x - last.x, dy: point.y - last.y)
    }

    override public func mouseUp(with event: NSEvent) { lastDrag = nil }

    override public func scrollWheel(with event: NSEvent) {
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 8
        zoom(by: 1 + delta / 200)
    }

    override public func magnify(with event: NSEvent) { zoom(by: 1 + event.magnification) }

    override public func cancelOperation(_ sender: Any?) { done() }

    /// Back to the automatic framing (the picture's subject clear of the panes).
    @objc public func reset() {
        backdrop.placements.set(nil, for: id)
        if let current = backdrop.adjustable?.current { placement = current }
    }

    /// Ends placing: the content comes back and the placement stays saved.
    @objc public func done() {
        if let updateObserver { NotificationCenter.default.removeObserver(updateObserver) }
        updateObserver = nil
        for (view, alpha) in faded { view.alphaValue = alpha }
        faded = []
        if Self.active === self { Self.active = nil }
        let window = window
        removeFromSuperview()
        window?.makeFirstResponder(window?.contentView)
    }

    static var hint: String {
        String(localized: "backdrop.adjust.hint", defaultValue: "Drag to move the picture. Scroll or pinch to zoom.", bundle: .module)
    }
    static var resetTitle: String { String(localized: "backdrop.adjust.reset", defaultValue: "Reset", bundle: .module) }
    static var doneTitle: String { String(localized: "backdrop.adjust.done", defaultValue: "Done", bundle: .module) }
}
