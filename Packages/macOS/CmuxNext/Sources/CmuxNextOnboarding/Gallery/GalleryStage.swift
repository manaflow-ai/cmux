import AppKit
import CmuxNextDesign

/// The center of the gallery: one variant live at real size, two side by
/// side at a smaller scale (Compare), or the whole flow running in place.
final class GalleryStage: NSView {
    static let compareScale: CGFloat = 0.64
    private var shown: [NSView] = []
    private var flowModel: OnboardingModel?

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    /// One live variant at real size (interactive, sample data).
    func show(_ variant: any OnboardingScreenVariant.Type, letter: String, services: any OnboardingServices) {
        clear()
        let box = frameBox(variant: variant, letter: letter, services: services, scale: 1, inert: false)
        place([box])
    }

    /// Two variants side by side (left: current, right: pinned), inert.
    func compare(_ left: (any OnboardingScreenVariant.Type, String), _ right: (any OnboardingScreenVariant.Type, String),
                 services: () -> any OnboardingServices) {
        clear()
        let boxes = [left, right].map { frameBox(variant: $0.0, letter: $0.1, services: services(), scale: Self.compareScale, inert: true) }
        place(boxes)
    }

    /// The real flow with the picks, in place; `onEnd` when it finishes or is skipped.
    func runFlow(services: any OnboardingServices, onEnd: @escaping () -> Void) {
        clear()
        let model = OnboardingModel(services: services)
        model.onEnd = { _ in onEnd() }
        flowModel = model
        let host = OnboardingHostView(model: model)
        let box = ScaledThumbnail(size: OnboardingMetrics.windowSize)
        box.show(host, fullSize: OnboardingMetrics.windowSize, interactive: true)
        model.stepDidAppear()
        place([box])
    }

    private func frameBox(variant: any OnboardingScreenVariant.Type, letter: String, services: any OnboardingServices,
                          scale: CGFloat, inert: Bool) -> NSView {
        let model = OnboardingModel(services: services, start: variant.step)
        let size = OnboardingMetrics.windowSize
        let box = ScaledThumbnail(size: NSSize(width: size.width * scale, height: size.height * scale))
        let screen = OnboardingSurfaceView(surface: variant.surface, content: variant.makeContent(OnboardingStepContext(model: model)))
        box.show(screen, fullSize: size, interactive: !inert)
        if inert { box.makeInert(label: letter) }
        model.stepDidAppear()
        let badge = OnboardingLabel.make(letter, font: .systemFont(ofSize: 13, weight: .bold), color: Palette.textPrimary)
        badge.wantsLayer = true
        let column = NSStackView(views: [box, badge])
        column.orientation = .vertical
        column.spacing = 8
        return column
    }

    private func place(_ views: [NSView]) {
        let row = NSStackView(views: views)
        row.spacing = 24
        row.alignment = .top
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([row.centerXAnchor.constraint(equalTo: centerXAnchor), row.centerYAnchor.constraint(equalTo: centerYAnchor)])
        shown = [row]
    }

    private func clear() {
        shown.forEach { $0.removeFromSuperview() }
        shown = []
        flowModel = nil
    }
}

/// A fixed-size box that draws a full-size screen at its own scale.
/// Interactive at real size; inert (one button, no focus) when scaled.
final class ScaledThumbnail: NSView {
    var onClick: (() -> Void)?
    private var fullSize: NSSize?
    private var interactive = true

    init(size: NSSize) {
        super.init(frame: NSRect(origin: .zero, size: size))
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        NSLayoutConstraint.activate([widthAnchor.constraint(equalToConstant: size.width), heightAnchor.constraint(equalToConstant: size.height)])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.borderColor = Palette.separator.cgColor }

    /// Scales the coordinate space first, then adds the screen at full size
    /// with no autoresizing (else AppKit shrinks it twice).
    func show(_ view: NSView, fullSize: NSSize, interactive: Bool) {
        self.fullSize = fullSize
        self.interactive = interactive
        bounds = NSRect(origin: .zero, size: fullSize)
        view.autoresizingMask = []
        view.frame = NSRect(origin: .zero, size: fullSize)
        addSubview(view)
    }

    override func layout() {
        super.layout()
        if let fullSize, bounds.size != fullSize { bounds = NSRect(origin: .zero, size: fullSize) }
    }

    /// The screen inside never takes keyboard focus or reaches VoiceOver.
    func makeInert(label: String) {
        interactive = false
        func disable(_ view: NSView) {
            (view as? NSControl)?.refusesFirstResponder = true
            view.setAccessibilityElement(false)
            view.subviews.forEach(disable)
        }
        subviews.forEach(disable)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel(label)
    }

    override func accessibilityChildren() -> [Any]? { interactive ? super.accessibilityChildren() : [] }
    override func hitTest(_ point: NSPoint) -> NSView? {
        interactive ? super.hitTest(point) : (frame.contains(point) ? self : nil)
    }
    override func mouseUp(with event: NSEvent) { onClick?() }
}
