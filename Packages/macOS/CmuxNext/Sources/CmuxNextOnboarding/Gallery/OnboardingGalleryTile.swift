import AppKit
import CmuxNextDesign

/// One variant, live at a uniform scale, with its name, idea, Open and Use This.
final class OnboardingGalleryTile: NSStackView {
    static let scale: CGFloat = 0.4
    private let variant: any OnboardingScreenVariant.Type
    private weak var gallery: OnboardingGalleryController?
    private let picks: any OnboardingServices
    private var useButton: NSButton!
    private let model: OnboardingModel
    private var pickLoop: RenderLoop?

    init(variant: any OnboardingScreenVariant.Type, gallery: OnboardingGalleryController, picks: any OnboardingServices,
         services: any OnboardingServices) {
        self.variant = variant
        self.gallery = gallery
        self.picks = picks
        model = OnboardingModel(services: services, start: variant.step)
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 6
        let size = OnboardingMetrics.windowSize
        let thumb = ScaledThumbnail(size: NSSize(width: size.width * Self.scale, height: size.height * Self.scale))
        let screen = OnboardingSurfaceView(surface: variant.surface, content: variant.makeContent(OnboardingStepContext(model: model)))
        thumb.show(screen, fullSize: size)
        thumb.onClick = { [weak self] in self?.open() }
        model.stepDidAppear()
        let name = OnboardingLabel.make(variant.name, font: .systemFont(ofSize: 13, weight: .semibold))
        let summary = OnboardingLabel.make(variant.summary, font: OnboardingMetrics.captionFont, color: Palette.textSecondary, lines: 2)
        let detail = OnboardingLabel.make("\(variant.surface.rawValue) · \(variant.transition.rawValue)", font: OnboardingMetrics.captionFont,
                                          color: Palette.textTertiary)
        let open = OnboardingControl.plainButton("Open", target: self, action: #selector(openPressed))
        useButton = OnboardingControl.button("Use This", target: self, action: #selector(usePressed))
        useButton.controlSize = .small
        let buttons = NSStackView(views: [useButton, open])
        buttons.spacing = 12
        for view in [thumb, name, summary, detail, buttons] as [NSView] { addArrangedSubview(view) }
        summary.widthAnchor.constraint(equalToConstant: thumb.frame.width).isActive = true
        setAccessibilityIdentifier("onboarding.gallery.tile.\(variant.id)")
        thumb.makeInert(label: variant.name)
        // The pick is written through cmux.json; follow the settings projection.
        pickLoop = RenderLoop { [weak self] in self?.refreshPick() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func refreshPick() {
        let chosen = OnboardingVariantRegistry.chosen(for: variant.step, id: picks.variantID(for: variant.step))
        let inUse = chosen.id == variant.id
        useButton.title = inUse ? "In Use" : "Use This"
        useButton.isEnabled = !inUse
    }

    @objc private func openPressed() { open() }
    @objc private func usePressed() { gallery?.use(variant) }
    private func open() { gallery?.openFullSize(variant) }
}

/// A fixed-size box that draws a full-size view scaled down and takes the
/// click itself, so the live screen inside never reacts.
final class ScaledThumbnail: NSView {
    var onClick: (() -> Void)?

    init(size: NSSize) {
        super.init(frame: NSRect(origin: .zero, size: size))
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        NSLayoutConstraint.activate([widthAnchor.constraint(equalToConstant: size.width), heightAnchor.constraint(equalToConstant: size.height)])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private var fullSize: NSSize?

    /// Scales the box's coordinate space to `fullSize` first, then adds the
    /// view at full size with no autoresizing (else AppKit shrinks it twice).
    func show(_ view: NSView, fullSize: NSSize) {
        self.fullSize = fullSize
        bounds = NSRect(origin: .zero, size: fullSize)
        view.autoresizingMask = []
        view.frame = NSRect(origin: .zero, size: fullSize)
        addSubview(view)
    }

    override var isFlipped: Bool { true }

    override func updateLayer() {
        super.updateLayer()
        layer?.borderColor = Palette.separator.cgColor
    }

    override var wantsUpdateLayer: Bool { true }

    override func layout() {
        super.layout()
        if let fullSize, bounds.size != fullSize { bounds = NSRect(origin: .zero, size: fullSize) }
    }

    /// The live screen inside never takes keyboard focus or reaches
    /// VoiceOver; the box is one button that opens the full-size preview.
    func makeInert(label: String) {
        func disable(_ view: NSView) {
            (view as? NSControl)?.refusesFirstResponder = true
            view.setAccessibilityElement(false)
            view.subviews.forEach(disable)
        }
        subviews.forEach(disable)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(label)
    }

    override func accessibilityChildren() -> [Any]? { [] }
    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return true
    }

    override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) ? self : nil }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) { onClick?() }
}
