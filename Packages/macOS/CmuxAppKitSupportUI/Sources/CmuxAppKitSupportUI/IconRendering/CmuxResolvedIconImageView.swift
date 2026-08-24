public import AppKit

/// AppKit image view that re-renders its icon when the window or effective appearance changes.
@MainActor
public final class CmuxResolvedIconImageView: NSView {
    private let imageView = NSImageView(frame: .zero)
    private let renderer = CmuxResolvedIconRenderer()
    private var request: CmuxResolvedIconRequest?
    private var renderKey: RenderKey?
    private var lastVisibleRenderKey: RenderKey?
    private var blankRenderKey: RenderKey?

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
        let nextKey = RenderKey(request: request, appearance: effectiveAppearance)
        guard force || renderKey != nextKey else { return }
        guard force || blankRenderKey?.shouldSkipBlankRetry(for: nextKey) != true else { return }
        switch renderer.render(for: request, appearance: effectiveAppearance) {
        case .success(let image):
            renderKey = nextKey
            lastVisibleRenderKey = nextKey
            blankRenderKey = nil
            imageView.image = image
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

    private struct RenderKey: Equatable {
        private let source: SourceKey
        private let canReuseRenderedImage: Bool
        private let width: CGFloat
        private let height: CGFloat
        private let tint: NSColor?
        private let symbolWeight: CGFloat
        private let appearanceName: NSAppearance.Name
        private let appearanceIdentity: ObjectIdentifier

        init(request: CmuxResolvedIconRequest, appearance: NSAppearance) {
            self.source = SourceKey(request.source)
            self.canReuseRenderedImage = source.canReuseRenderedImage
            self.width = request.size.width
            self.height = request.size.height
            self.tint = request.tintColor
            self.symbolWeight = request.symbolWeight.rawValue
            self.appearanceName = appearance.name
            self.appearanceIdentity = ObjectIdentifier(appearance)
        }

        static func == (lhs: RenderKey, rhs: RenderKey) -> Bool {
            lhs.canReuseRenderedImage && rhs.canReuseRenderedImage && lhs.matchesRequestAndAppearance(rhs)
        }

        func matchesRequestAndAppearance(_ other: RenderKey) -> Bool {
            source == other.source &&
                width == other.width &&
                height == other.height &&
                symbolWeight == other.symbolWeight &&
                appearanceName == other.appearanceName &&
                appearanceIdentity == other.appearanceIdentity &&
                Self.colorsEqual(tint, other.tint)
        }

        func shouldSkipBlankRetry(for other: RenderKey) -> Bool {
            canReuseRenderedImage && other.canReuseRenderedImage && matchesRequestAndAppearance(other)
        }

        private static func colorsEqual(_ lhs: NSColor?, _ rhs: NSColor?) -> Bool {
            switch (lhs, rhs) {
            case (.none, .none):
                return true
            case let (lhs?, rhs?):
                return lhs.isEqual(rhs)
            default:
                return false
            }
        }

        private enum SourceKey: Equatable {
            case systemSymbol(name: String, accessibilityDescription: String?)
            case asset(name: String, bundle: ObjectIdentifier)
            case image(ObjectIdentifier)

            init(_ source: CmuxResolvedIconSource) {
                switch source {
                case .systemSymbol(let name, let accessibilityDescription):
                    self = .systemSymbol(name: name, accessibilityDescription: accessibilityDescription)
                case .asset(let name, let bundle):
                    self = .asset(name: name, bundle: ObjectIdentifier(bundle))
                case .image(let image):
                    self = .image(ObjectIdentifier(image))
                }
            }

            var canReuseRenderedImage: Bool {
                switch self {
                case .systemSymbol, .asset:
                    return true
                case .image:
                    return false
                }
            }
        }
    }
}
