public import AppKit

/// AppKit image view that re-renders its icon when the window or effective appearance changes.
///
/// The rendered bitmap already carries every intended opacity (tint, hover,
/// disabled), so it is drawn as-is by ``BitmapView`` rather than an
/// `NSImageView`. `NSImageView` in a titlebar dims its image to about 45%
/// whenever the window is not key, which made titlebar symbols change color
/// on focus loss while drawn chrome beside them did not.
@MainActor
public final class CmuxResolvedIconImageView: NSView {
    private let imageView = BitmapView(frame: .zero)
    private let renderer = CmuxResolvedIconRenderer()
    private var request: CmuxResolvedIconRequest?
    private var renderKey: RenderKey?
    private var lastVisibleRenderKey: RenderKey?
    private var blankRenderKey: RenderKey?

    /// Creates the resolved icon view.
    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        imageView.translatesAutoresizingMaskIntoConstraints = false
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
        private let fallbackSource: SourceKey?
        private let canReuseRenderedImage: Bool
        private let width: CGFloat
        private let height: CGFloat
        private let tint: NSColor?
        private let fallbackTint: NSColor?
        private let symbolWeight: CGFloat
        private let symbolPointSize: CGFloat?
        private let appearanceName: NSAppearance.Name
        private let appearanceIdentity: ObjectIdentifier

        init(request: CmuxResolvedIconRequest, appearance: NSAppearance) {
            self.source = SourceKey(request.source)
            self.fallbackSource = request.fallbackSource.map(SourceKey.init)
            // Any mutable source disables key reuse. This applies to the
            // fallback as well: the public request can carry an NSImage whose
            // representations change in place between updates.
            self.canReuseRenderedImage = source.canReuseRenderedImage
                && (fallbackSource?.canReuseRenderedImage ?? true)
            self.width = request.size.width
            self.height = request.size.height
            self.tint = request.tintColor
            self.fallbackTint = request.fallbackTintColor
            self.symbolWeight = request.symbolWeight.rawValue
            self.symbolPointSize = request.symbolPointSize
            self.appearanceName = appearance.name
            self.appearanceIdentity = ObjectIdentifier(appearance)
        }

        static func == (lhs: RenderKey, rhs: RenderKey) -> Bool {
            lhs.canReuseRenderedImage && rhs.canReuseRenderedImage && lhs.matchesRequestAndAppearance(rhs)
        }

        func matchesRequestAndAppearance(_ other: RenderKey) -> Bool {
            source == other.source &&
                fallbackSource == other.fallbackSource &&
                width == other.width &&
                height == other.height &&
                symbolWeight == other.symbolWeight &&
                symbolPointSize == other.symbolPointSize &&
                appearanceName == other.appearanceName &&
                appearanceIdentity == other.appearanceIdentity &&
                Self.colorsEqual(tint, other.tint) &&
                Self.colorsEqual(fallbackTint, other.fallbackTint)
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
            case workspaceIcon(String)

            init(_ source: CmuxResolvedIconSource) {
                switch source {
                case .systemSymbol(let name, let accessibilityDescription):
                    self = .systemSymbol(name: name, accessibilityDescription: accessibilityDescription)
                case .asset(let name, let bundle):
                    self = .asset(name: name, bundle: ObjectIdentifier(bundle))
                case .image(let image):
                    self = .image(ObjectIdentifier(image))
                case .workspaceIcon(let type):
                    self = .workspaceIcon(type.identifier)
                }
            }

            var canReuseRenderedImage: Bool {
                switch self {
                case .systemSymbol, .asset:
                    return true
                case .workspaceIcon:
                    return true
                case .image:
                    return false
                }
            }
        }
    }
}

/// Draws a pre-rendered bitmap centered in its bounds, scaled down (never up)
/// to fit, matching `NSImageView`'s `.scaleProportionallyDown` +
/// `.alignCenter` layout without its window-activity and enabled-state dimming.
@MainActor
final class BitmapView: NSView {
    var image: NSImage? {
        didSet {
            guard image !== oldValue else { return }
            if image?.size != oldValue?.size {
                invalidateIntrinsicContentSize()
            }
            needsDisplay = true
        }
    }

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        image?.size ?? NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let image, image.size.width > 0, image.size.height > 0 else { return }
        image.draw(
            in: Self.drawRect(imageSize: image.size, in: bounds),
            from: .zero,
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: true,
            hints: nil
        )
    }

    /// The image rect: its natural size, shrunk proportionally when larger
    /// than `bounds`, centered and pixel-aligned in points.
    nonisolated static func drawRect(imageSize: NSSize, in bounds: NSRect) -> NSRect {
        let scale = min(1, bounds.width / imageSize.width, bounds.height / imageSize.height)
        let size = NSSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return NSRect(
            x: (bounds.midX - size.width / 2).rounded(),
            y: (bounds.midY - size.height / 2).rounded(),
            width: size.width,
            height: size.height
        )
    }
}
