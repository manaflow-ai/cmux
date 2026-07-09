public import AppKit

/// AppKit image view that re-renders its icon when the window or effective appearance changes.
@MainActor
public final class CmuxResolvedIconImageView: NSView {
    private let imageView = NSImageView(frame: .zero)
    private let renderer = CmuxResolvedIconRenderer()
    private var request: CmuxResolvedIconRequest?

    /// The last rendered image, exposed for callers that need to inspect the AppKit result.
    public var renderedImage: NSImage? {
        imageView.image
    }

    /// Creates the resolved icon view.
    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.imageScaling = .scaleProportionallyDown
        imageView.imageAlignment = .alignCenter
        imageView.animates = false
        imageView.contentTintColor = nil
        addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor),
            imageView.topAnchor.constraint(equalTo: topAnchor),
            imageView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Applies a new icon request and immediately renders it for the current appearance.
    public func apply(_ request: CmuxResolvedIconRequest?) {
        self.request = request
        updateAccessibilityDescription(request?.accessibilityDescription)
        render()
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        render()
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        render()
    }

    private func render() {
        guard let request else {
            imageView.image = nil
            return
        }
        imageView.image = renderer.image(for: request, appearance: effectiveAppearance)
        imageView.contentTintColor = nil
    }

    private func updateAccessibilityDescription(_ description: String?) {
        guard let description, !description.isEmpty else {
            imageView.setAccessibilityElement(false)
            imageView.setAccessibilityLabel(nil)
            return
        }
        imageView.setAccessibilityElement(true)
        imageView.setAccessibilityRole(.image)
        imageView.setAccessibilityLabel(description)
    }
}
