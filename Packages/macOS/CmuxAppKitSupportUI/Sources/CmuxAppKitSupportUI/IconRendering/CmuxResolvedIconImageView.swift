public import AppKit

/// AppKit image view that re-renders its icon when the window or effective appearance changes.
@MainActor
public final class CmuxResolvedIconImageView: NSView {
    private let imageView = NSImageView(frame: .zero)
    private let renderer = CmuxResolvedIconRenderer()
    private var request: CmuxResolvedIconRequest?
    private var renderKey: RenderKey?

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
            imageView.image = nil
            return
        }
        let nextKey = RenderKey(request: request, appearance: effectiveAppearance)
        guard force || renderKey != nextKey else { return }
        renderKey = nextKey
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

    private struct RenderKey: Equatable {
        let source: String
        let width: CGFloat
        let height: CGFloat
        let tint: String?
        let symbolWeight: CGFloat
        let appearanceName: String

        init(request: CmuxResolvedIconRequest, appearance: NSAppearance) {
            self.source = Self.sourceKey(request.source)
            self.width = request.size.width
            self.height = request.size.height
            self.tint = request.tintColor.map(String.init(describing:))
            self.symbolWeight = request.symbolWeight.rawValue
            self.appearanceName = appearance.bestMatch(from: [.darkAqua, .aqua])?.rawValue ?? appearance.name.rawValue
        }

        private static func sourceKey(_ source: CmuxResolvedIconSource) -> String {
            switch source {
            case .systemSymbol(let name, let accessibilityDescription):
                "symbol:\(name):\(accessibilityDescription ?? "")"
            case .asset(let name, let bundle):
                "asset:\(name):\(bundle.bundleIdentifier ?? bundle.bundlePath)"
            case .image(let image):
                "image:\(ObjectIdentifier(image).hashValue):\(image.size.width):\(image.size.height)"
            }
        }
    }
}
