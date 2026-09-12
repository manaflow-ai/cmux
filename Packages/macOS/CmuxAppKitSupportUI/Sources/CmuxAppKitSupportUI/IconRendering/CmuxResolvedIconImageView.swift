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
    /// Layout passes a blank draw may use to recover before the view gives
    /// up until its window or effective appearance changes. A transparent
    /// first raster is a transient AppKit state (the symbol provider resolved
    /// before the effective appearance did); by the time AppKit lays the view
    /// out inside its window the appearance is resolved, so the next layout
    /// pass is the readiness signal. A source that stays blank stops after
    /// this many passes.
    static let blankRecoveryLayoutPasses = 3
    private(set) var blankRecoveryPassesUsed = 0

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

    public override func layout() {
        super.layout()
        recoverBlankRenderIfNeeded()
    }

    /// Re-renders a blank draw during a layout pass, when the view is inside
    /// its window and AppKit has resolved the effective appearance.
    private func recoverBlankRenderIfNeeded() {
        guard blankRenderKey != nil,
              blankRecoveryPassesUsed < Self.blankRecoveryLayoutPasses else { return }
        blankRecoveryPassesUsed += 1
        renderIfNeeded(force: true)
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
        if blankRenderKey?.matchesRequestAndAppearance(nextKey) != true {
            // A different request or appearance gets a fresh recovery budget.
            blankRecoveryPassesUsed = 0
        }
        switch renderer.render(for: request, appearance: effectiveAppearance) {
        case .success(let image):
            renderKey = nextKey
            lastVisibleRenderKey = nextKey
            blankRenderKey = nil
            blankRecoveryPassesUsed = 0
            imageView.image = image
        case .failure(.sourceUnavailable):
            renderKey = nextKey
            lastVisibleRenderKey = nil
            blankRenderKey = nil
            blankRecoveryPassesUsed = 0
            imageView.image = nil
        case .failure(.blankOutput):
            renderKey = nil
            blankRenderKey = nextKey
            if lastVisibleRenderKey?.matchesRequestAndAppearance(nextKey) != true {
                lastVisibleRenderKey = nil
                imageView.image = nil
            }
            if blankRecoveryPassesUsed < Self.blankRecoveryLayoutPasses {
                // Ask AppKit for a layout pass; `layout()` retries the draw
                // once the view is laid out inside its window.
                needsLayout = true
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
