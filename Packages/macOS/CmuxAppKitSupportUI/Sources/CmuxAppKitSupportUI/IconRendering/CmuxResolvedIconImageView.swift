public import AppKit

/// AppKit image view that re-renders its icon when the window or effective appearance changes.
@MainActor
public final class CmuxResolvedIconImageView: NSView {
    private static let renderedImageCache = CmuxResolvedIconRenderCache(limit: 128)

    private let imageView = NSImageView(frame: .zero)
    private let renderer = CmuxResolvedIconRenderer()
    private var request: CmuxResolvedIconRequest?
    private var renderKey: CmuxResolvedIconRenderKey?
    private var lastVisibleRenderKey: CmuxResolvedIconRenderKey?
    private var blankRenderKey: CmuxResolvedIconRenderKey?

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
        renderIfNeeded(force: false)
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        renderIfNeeded(force: true)
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        renderIfNeeded(force: false)
    }

    private func renderIfNeeded(force: Bool) {
        guard let request else {
            renderKey = nil
            lastVisibleRenderKey = nil
            blankRenderKey = nil
            imageView.image = nil
            return
        }
        let nextKey = CmuxResolvedIconRenderKey(request: request, appearance: effectiveAppearance)
        guard force || renderKey?.shouldSkipRender(for: nextKey) != true else { return }
        guard force || blankRenderKey?.shouldSkipBlankRetry(for: nextKey) != true else { return }
        if let reusableKey = nextKey.reusableKey,
           let cachedImage = Self.renderedImageCache.image(for: reusableKey, matching: nextKey) {
            renderKey = nextKey
            lastVisibleRenderKey = nextKey
            blankRenderKey = nil
            imageView.image = cachedImage
            imageView.contentTintColor = nil
            return
        }
        switch renderer.render(for: request, appearance: effectiveAppearance) {
        case .success(let image):
            renderKey = nextKey
            lastVisibleRenderKey = nextKey
            blankRenderKey = nil
            imageView.image = image
            if let reusableKey = nextKey.reusableKey {
                Self.renderedImageCache.insert(image, for: reusableKey, renderKey: nextKey)
            }
        case .failure(.sourceUnavailable):
            renderKey = nextKey
            lastVisibleRenderKey = nil
            blankRenderKey = nil
            imageView.image = nil
        case .failure(.blankOutput):
            renderKey = nil
            blankRenderKey = nextKey
            guard lastVisibleRenderKey?.matchesRequestAndAppearance(nextKey) == true else {
                lastVisibleRenderKey = nil
                imageView.image = nil
                break
            }
        }
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
