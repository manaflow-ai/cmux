public import AppKit
import CmuxNextDesign
import Observation

/// The sidebar: a flat surface on the window background (the terminal
/// theme's background), with no panel, border or seam. It owns its width.
///
/// Pin leading, top, and bottom; the view animates its own width constraint
/// for `SidebarModel.presentation` (expanded, icons only, hidden) and for
/// live resizing through the trailing handle. Neighbors should attach to its
/// trailing anchor so they follow.
public final class SidebarContainerView: NSView {
    public let sidebarView: SidebarView
    public let model: SidebarModel
    /// The width constraint this view drives. Do not add another.
    public private(set) var widthConstraint: NSLayoutConstraint!

    /// Plain holder; alpha fades the sidebar out when hidden.
    private let panel = NSView()
    private let handle: SidebarResizeHandle
    private var observation: Task<Void, Never>?

    /// Dragging narrower than this switches to icons-only; dragging an
    /// icons-only sidebar wider than this expands it.
    public static var collapseThreshold: CGFloat { (Metrics.sidebarMinWidth + Metrics.sidebarCollapsedWidth) / 2 }

    public init(model: SidebarModel) {
        self.model = model
        sidebarView = SidebarView(model: model)
        handle = SidebarResizeHandle()
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        panel.translatesAutoresizingMaskIntoConstraints = false
        sidebarView.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(sidebarView)
        addSubview(panel)
        addSubview(handle)
        handle.translatesAutoresizingMaskIntoConstraints = false
        widthConstraint = widthAnchor.constraint(equalToConstant: model.displayWidth)
        NSLayoutConstraint.activate([
            widthConstraint,
            sidebarView.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            sidebarView.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
            sidebarView.topAnchor.constraint(equalTo: panel.topAnchor),
            sidebarView.bottomAnchor.constraint(equalTo: panel.bottomAnchor),
            panel.leadingAnchor.constraint(equalTo: leadingAnchor),
            panel.topAnchor.constraint(equalTo: topAnchor),
            panel.bottomAnchor.constraint(equalTo: bottomAnchor),
            panel.trailingAnchor.constraint(equalTo: trailingAnchor),
            handle.trailingAnchor.constraint(equalTo: trailingAnchor, constant: Metrics.dividerHitWidth / 2),
            handle.topAnchor.constraint(equalTo: topAnchor),
            handle.bottomAnchor.constraint(equalTo: bottomAnchor),
            handle.widthAnchor.constraint(equalToConstant: Metrics.dividerHitWidth),
        ])
        panel.alphaValue = model.presentation == .hidden ? 0 : 1
        handle.onDrag = { [weak self] phase in self?.handleDrag(phase) }
        observe()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    isolated deinit {
        observation?.cancel()
    }

    private var liveStartWidth: CGFloat = 0

    private func handleDrag(_ phase: SidebarResizeHandle.Phase) {
        switch phase {
        case .began:
            liveStartWidth = model.displayWidth
        case let .changed(dx):
            let proposed = liveStartWidth + dx
            switch model.presentation {
            case .expanded:
                if proposed < Self.collapseThreshold {
                    model.presentation = .iconsOnly
                } else {
                    model.width = proposed
                    widthConstraint.constant = model.width
                }
            case .iconsOnly:
                if proposed > Self.collapseThreshold {
                    model.width = max(proposed, SidebarModel.widthRange.lowerBound)
                    model.presentation = .expanded
                }
            case .hidden:
                break
            }
        case .ended:
            break
        case .doubleClick:
            model.togglePresentation()
        }
    }

    private func observe() {
        let model = model
        observation = Task { [weak self] in
            for await (presentation, width, _, defaultWidth) in Observations({
                // displayWidth reads Metrics.sidebarCollapsedWidth; the default
                // width token is tracked so a settings change resizes live.
                (model.presentation, model.width, model.displayWidth, Metrics.sidebarWidth)
            }) {
                self?.followDefaultWidth(defaultWidth)
                self?.apply(presentation: presentation, width: width)
            }
        }
    }

    private var lastDefaultWidth: CGFloat?

    /// When the user changes the sidebar width setting, adopt it.
    private func followDefaultWidth(_ value: CGFloat) {
        defer { lastDefaultWidth = value }
        guard let last = lastDefaultWidth, last != value else { return }
        model.width = value
    }

    private func apply(presentation: SidebarPresentation, width: CGFloat) {
        let target = model.displayWidth
        handle.isHidden = presentation == .hidden
        guard widthConstraint.constant != target else { return }
        if handle.isDragging, presentation == .expanded, widthConstraint.constant > Self.collapseThreshold {
            widthConstraint.constant = target
            return
        }
        let alpha: CGFloat = presentation == .hidden ? 0 : 1
        // Animate only the constraint: descendants re-lay out each frame at
        // their real size. Forcing layout inside the animation block would
        // make every subview frame an implicit animation whose completion
        // overwrites later layout.
        Motion.animate(Motion.width) {
            widthConstraint.animator().constant = target
            panel.animator().alphaValue = alpha
        }
    }
}

/// Strip on the sidebar's trailing edge that resizes it. Invisible until
/// the pointer is over it; then a hairline fades in (and stays while
/// dragging), so the edge never shows as a seam at rest.
final class SidebarResizeHandle: NSView {
    enum Phase {
        case began
        case changed(CGFloat)
        case ended
        case doubleClick
    }

    var onDrag: ((Phase) -> Void)?
    private(set) var isDragging = false { didSet { updateLine() } }
    private(set) var isHovered = false { didSet { updateLine() } }
    private var startX: CGFloat = 0
    private let line = CALayer()

    /// The hairline shows only on hover or while dragging.
    var isLineVisible: Bool { isHovered || isDragging }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        line.opacity = 0
        layer?.addSublayer(line)
        setAccessibilityElement(true)
        setAccessibilityRole(.splitter)
        setAccessibilityLabel(Strings.resize)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .columnResize)
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        line.frame = CGRect(x: (bounds.width - Metrics.dividerThickness) / 2, y: 0, width: Metrics.dividerThickness, height: bounds.height)
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        line.backgroundColor = resolvedCGColor(Palette.separator)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        line.backgroundColor = resolvedCGColor(Palette.separator)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    func setHovered(_ hovered: Bool) { isHovered = hovered }

    private func updateLine() {
        let target: Float = isLineVisible ? 1 : 0
        guard line.opacity != target else { return }
        if !Motion.reduceMotion {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = line.presentation()?.opacity ?? line.opacity
            fade.toValue = target
            fade.duration = 0.14
            line.add(fade, forKey: "opacity")
        }
        line.opacity = target
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onDrag?(.doubleClick)
            return
        }
        isDragging = true
        startX = event.locationInWindow.x
        onDrag?(.began)
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDragging else { return }
        onDrag?(.changed(event.locationInWindow.x - startX))
    }

    override func mouseUp(with event: NSEvent) {
        guard isDragging else { return }
        isDragging = false
        onDrag?(.ended)
    }
}
