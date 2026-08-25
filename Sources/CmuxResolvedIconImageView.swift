import AppKit

/// Owns one icon's render lifecycle across window and appearance changes.
@MainActor
final class CmuxResolvedIconImageView: NSView {
    private let imageView = NSImageView(frame: .zero)
    private let renderer = CmuxResolvedIconRenderer()
    private var request: CmuxResolvedIconRequest?
    private var renderKey: RenderKey?
    private var blankRenderKey: RenderKey?
    private var lastVisibleImage: NSImage?
    private var lastVisibleRenderKey: RenderKey?

    override init(frame frameRect: NSRect) {
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
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Applies a request immediately using the view's current appearance.
    func apply(_ request: CmuxResolvedIconRequest?) {
        self.request = request
        updateAccessibilityDescription(request?.accessibilityDescription)
        renderIfNeeded(force: false)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        renderIfNeeded(force: true)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        renderIfNeeded(force: false)
    }

    private func renderIfNeeded(force: Bool) {
        guard let request else {
            renderKey = nil
            blankRenderKey = nil
            lastVisibleImage = nil
            lastVisibleRenderKey = nil
            imageView.image = nil
            return
        }

        let nextKey = RenderKey(request: request, appearance: effectiveAppearance)
        guard force || renderKey != nextKey else { return }
        guard force || blankRenderKey?.matches(nextKey) != true else { return }

        switch renderer.render(for: request, appearance: effectiveAppearance) {
        case .success(let image):
            renderKey = nextKey
            blankRenderKey = nil
            lastVisibleImage = image
            lastVisibleRenderKey = nextKey
            imageView.image = image
        case .failure(.sourceUnavailable):
            renderKey = nextKey
            blankRenderKey = nil
            lastVisibleImage = nil
            lastVisibleRenderKey = nil
            imageView.image = nil
        case .failure(.blankOutput):
            renderKey = nil
            blankRenderKey = nextKey
            if let lastVisibleImage,
               lastVisibleRenderKey?.matchesRequest(nextKey) == true {
                imageView.image = lastVisibleImage
            } else {
                self.lastVisibleImage = nil
                lastVisibleRenderKey = nil
                imageView.image = nil
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

    private struct RenderKey: Equatable {
        let source: SourceKey
        let canReuseRenderedImage: Bool
        let size: NSSize
        let tint: NSColor?
        let symbolWeight: CGFloat
        let appearanceName: NSAppearance.Name
        let appearanceIdentity: ObjectIdentifier

        init(request: CmuxResolvedIconRequest, appearance: NSAppearance) {
            source = SourceKey(request.sources)
            canReuseRenderedImage = request.sources.allSatisfy { source in
                if case .image = source {
                    return false
                }
                return true
            }
            size = request.size
            tint = request.tintColor
            symbolWeight = request.symbolWeight.rawValue
            appearanceName = appearance.name
            appearanceIdentity = ObjectIdentifier(appearance)
        }

        func matches(_ other: RenderKey) -> Bool {
            canReuseRenderedImage && other.canReuseRenderedImage &&
                matchesRequest(other) &&
                appearanceName == other.appearanceName &&
                appearanceIdentity == other.appearanceIdentity
        }

        func matchesRequest(_ other: RenderKey) -> Bool {
            source == other.source &&
                size == other.size &&
                symbolWeight == other.symbolWeight &&
                colorsEqual(tint, other.tint)
        }

        static func == (lhs: RenderKey, rhs: RenderKey) -> Bool {
            lhs.matches(rhs)
        }

        private func colorsEqual(_ lhs: NSColor?, _ rhs: NSColor?) -> Bool {
            switch (lhs, rhs) {
            case (.none, .none):
                return true
            case let (lhs?, rhs?):
                return lhs.isEqual(rhs)
            default:
                return false
            }
        }
    }

    private enum SourceKey: Equatable {
        case systemSymbol(name: String, accessibilityDescription: String?)
        case asset(name: String, bundle: ObjectIdentifier)
        case image(ObjectIdentifier)
        case empty

        init(_ sources: [CmuxResolvedIconSource]) {
            guard let first = sources.first else {
                self = .empty
                return
            }
            switch first {
            case .systemSymbol(let name, let accessibilityDescription):
                self = .systemSymbol(name: name, accessibilityDescription: accessibilityDescription)
            case .asset(let name, let bundle):
                self = .asset(name: name, bundle: ObjectIdentifier(bundle))
            case .image(let image):
                self = .image(ObjectIdentifier(image))
            }
        }
    }
}
