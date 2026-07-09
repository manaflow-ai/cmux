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
        private let source: SourceKey
        private let width: CGFloat
        private let height: CGFloat
        private let tint: NSColor?
        private let symbolWeight: CGFloat
        private let appearanceName: NSAppearance.Name
        private let appearanceIdentity: ObjectIdentifier

        init(request: CmuxResolvedIconRequest, appearance: NSAppearance) {
            self.source = SourceKey(request.source)
            self.width = request.size.width
            self.height = request.size.height
            self.tint = request.tintColor
            self.symbolWeight = request.symbolWeight.rawValue
            self.appearanceName = appearance.name
            self.appearanceIdentity = ObjectIdentifier(appearance)
        }

        static func == (lhs: RenderKey, rhs: RenderKey) -> Bool {
            lhs.source == rhs.source &&
                lhs.width == rhs.width &&
                lhs.height == rhs.height &&
                lhs.symbolWeight == rhs.symbolWeight &&
                lhs.appearanceName == rhs.appearanceName &&
                lhs.appearanceIdentity == rhs.appearanceIdentity &&
                colorsEqual(lhs.tint, rhs.tint)
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
            case image(ImageKey)

            init(_ source: CmuxResolvedIconSource) {
                switch source {
                case .systemSymbol(let name, let accessibilityDescription):
                    self = .systemSymbol(name: name, accessibilityDescription: accessibilityDescription)
                case .asset(let name, let bundle):
                    self = .asset(name: name, bundle: ObjectIdentifier(bundle))
                case .image(let image):
                    self = .image(ImageKey(image))
                }
            }
        }

        private struct ImageKey: Equatable {
            private let identity: ObjectIdentifier
            private let width: CGFloat
            private let height: CGFloat
            private let isTemplate: Bool
            private let representations: [ImageRepresentationKey]

            init(_ image: NSImage) {
                self.identity = ObjectIdentifier(image)
                self.width = image.size.width
                self.height = image.size.height
                self.isTemplate = image.isTemplate
                self.representations = image.representations.map(ImageRepresentationKey.init)
            }
        }

        private struct ImageRepresentationKey: Equatable {
            private let identity: ObjectIdentifier
            private let classIdentity: ObjectIdentifier
            private let pixelsWide: Int
            private let pixelsHigh: Int
            private let width: CGFloat
            private let height: CGFloat
            private let bitsPerSample: Int
            private let hasAlpha: Bool
            private let isOpaque: Bool
            private let colorSpaceName: NSColorSpaceName

            init(_ representation: NSImageRep) {
                self.identity = ObjectIdentifier(representation)
                self.classIdentity = ObjectIdentifier(type(of: representation))
                self.pixelsWide = representation.pixelsWide
                self.pixelsHigh = representation.pixelsHigh
                self.width = representation.size.width
                self.height = representation.size.height
                self.bitsPerSample = representation.bitsPerSample
                self.hasAlpha = representation.hasAlpha
                self.isOpaque = representation.isOpaque
                self.colorSpaceName = representation.colorSpaceName
            }
        }
    }
}
