import AppKit

/// A tooltip drawn in place for the Tooltip Gallery: the panel's own surface (``Glass/makeTooltipGlass(cornerRadius:interactive:)``)
/// and content (``TooltipContentView``), sized as the panel sizes them, in the theme scope it sits in.
@MainActor
final class TooltipGalleryTooltip: NSView {
    let surface: OverlaySurfaceView
    let content = TooltipContentView()
    private let sample: TooltipGallerySample

    init(_ sample: TooltipGallerySample) {
        self.sample = sample
        surface = Glass.makeTooltipGlass(cornerRadius: TooltipPanel.radius)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        if sample.opaque { surface.materialOverride = .opaque }
        surface.translatesAutoresizingMaskIntoConstraints = true
        addSubview(surface)
        content.translatesAutoresizingMaskIntoConstraints = true
        surface.contentView.addSubview(content)
        content.set(text: sample.text, shortcut: sample.shortcut)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") } // crash-allow: never decoded from a nib

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize { content.fittingSurfaceSize(maxWidth: TooltipPanel.maxWidth) }

    override func layout() {
        super.layout()
        let size = intrinsicContentSize
        surface.frame = NSRect(origin: .zero, size: size)
        content.frame = surface.bounds
        surface.applyTheme()
        paint()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        surface.refreshMaterial()
        needsLayout = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        paint()
    }

    /// The panel's colors in this view's theme scope.
    private func paint() {
        let style = performWithTheme { TooltipStyle.current() }
        content.paint(ink: style.ink, hint: style.hint)
    }
}
