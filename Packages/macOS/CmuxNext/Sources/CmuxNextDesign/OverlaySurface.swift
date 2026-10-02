public import AppKit

/// How an app overlay that floats over content (the tab drag's drop
/// target) is drawn. One decision for every OS and accessibility setting.
public enum OverlayMaterial: Equatable, Sendable {
    /// Real Liquid Glass (`NSGlassEffectView`, macOS 26 and later).
    case liquidGlass
    /// Before Liquid Glass: a behind-window blur (`NSVisualEffectView`)
    /// with a Ghostty-derived tint and a hairline border.
    case vibrancy
    /// Reduce Transparency: an opaque Ghostty-derived fill with a hairline
    /// border, no blur and no glass.
    case opaque

    /// The material for an OS that has (or lacks) Liquid Glass and the
    /// user's Reduce Transparency setting.
    public static func select(liquidGlassAvailable: Bool, reduceTransparency: Bool) -> OverlayMaterial {
        if reduceTransparency { return .opaque }
        return liquidGlassAvailable ? .liquidGlass : .vibrancy
    }

    /// Whether this OS has Liquid Glass (macOS 26 and later). A runtime
    /// check, so the selection stays testable for every OS.
    public static var liquidGlassAvailable: Bool {
        ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0))
    }

    /// The material for this Mac now.
    @MainActor public static var current: OverlayMaterial {
        select(liquidGlassAvailable: liquidGlassAvailable,
               reduceTransparency: NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency)
    }
}

/// An overlay surface drawn in an `OverlayMaterial`, with one shape (a
/// continuous rounded rect of `cornerRadius`) whatever the material, so the
/// overlay's frame, corners and motion are the same on every path. It
/// follows Reduce Transparency live and re-reads theme colors in
/// `applyTheme()`. Content goes in `contentView`, above the material.
@MainActor
public final class OverlaySurfaceView: NSView {
    public private(set) var material: OverlayMaterial
    public let contentView = NSView()
    private var materialView: NSView?
    private var tintView: NSView?
    private var observer: (any NSObjectProtocol)?
    /// Pins one material (tests, `debug.drop_highlight`); nil follows this Mac.
    public var materialOverride: OverlayMaterial? {
        didSet { refreshMaterial() }
    }

    public var cornerRadius: CGFloat = Metrics.panelCornerRadius {
        didSet { if cornerRadius != oldValue { applyShape() } }
    }

    /// `material` pins one material (tests, previews); nil follows this Mac.
    public init(material: OverlayMaterial? = nil) {
        materialOverride = material
        self.material = material ?? OverlayMaterial.current
        super.init(frame: .zero)
        wantsLayer = true
        contentView.translatesAutoresizingMaskIntoConstraints = true
        contentView.autoresizingMask = [.width, .height]
        rebuild()
        observer = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: nil
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshMaterial() }
            }
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    isolated deinit {
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }

    /// The view that draws the material (an `NSGlassEffectView`,
    /// `NSVisualEffectView` or a plain layer-backed view).
    public var materialDrawingView: NSView? { materialView }

    public override func hitTest(_ point: NSPoint) -> NSView? { nil }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTheme()
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyTheme()
    }

    /// Re-reads the material from this Mac's settings (Reduce Transparency).
    public func refreshMaterial() {
        let next = materialOverride ?? OverlayMaterial.current
        guard next != material else { return }
        material = next
        rebuild()
    }

    private func rebuild() {
        materialView?.removeFromSuperview()
        contentView.removeFromSuperview()
        tintView = nil
        let view: NSView
        switch material {
        case .liquidGlass:
            let glass = Glass.makePanel(content: contentView, style: .regular, cornerRadius: cornerRadius)
            glass.translatesAutoresizingMaskIntoConstraints = true
            view = glass
        case .vibrancy:
            let effect = NSVisualEffectView()
            effect.material = .popover
            effect.blendingMode = .withinWindow
            effect.state = .active
            effect.wantsLayer = true
            // The Ghostty-derived tint sits on the blur, under the content.
            let tint = NSView(frame: effect.bounds)
            tint.wantsLayer = true
            tint.autoresizingMask = [.width, .height]
            tint.addSubview(contentView)
            effect.addSubview(tint)
            tintView = tint
            view = effect
        case .opaque:
            let plain = NSView()
            plain.wantsLayer = true
            plain.addSubview(contentView)
            view = plain
        }
        view.frame = bounds
        view.autoresizingMask = [.width, .height]
        // NSGlassEffectView lays its contentView out with constraints; out
        // of the glass it must size by its frame again.
        if material != .liquidGlass {
            contentView.translatesAutoresizingMaskIntoConstraints = true
            contentView.autoresizingMask = [.width, .height]
            tintView?.frame = view.bounds
            contentView.frame = view.bounds
        }
        addSubview(view)
        materialView = view
        applyShape()
        applyTheme()
    }

    private func applyShape() {
        if let glass = materialView as? NSGlassEffectView {
            glass.cornerRadius = cornerRadius
        } else if let layer = materialView?.layer {
            layer.cornerRadius = cornerRadius
            layer.cornerCurve = .continuous
            layer.masksToBounds = true
            layer.borderWidth = Metrics.lineWidth(1 / max(window?.backingScaleFactor ?? 2, 1))
        }
    }

    /// Theme colors: the glass tint, or the fallback's Ghostty-derived fill
    /// and hairline. Never an accent color.
    public func applyTheme() {
        performWithTheme {
            switch material {
            case .liquidGlass:
                (materialView as? NSGlassEffectView)?.tintColor = overlayTint
            case .vibrancy:
                tintView?.layer?.backgroundColor = overlayTint.cgColor
                materialView?.layer?.borderColor = Palette.separator.cgColor
            case .opaque:
                let base = Palette.windowBackground.usingColorSpace(.sRGB) ?? Palette.windowBackground
                let fill = base.withAlphaComponent(1).blended(withFraction: ChromeTunables.opaqueOverlayLift.value, of: Palette.textPrimary.withAlphaComponent(1)) ?? base
                materialView?.layer?.backgroundColor = fill.cgColor
                materialView?.layer?.borderColor = Palette.separator.withAlphaComponent(1).cgColor
            }
        }
        applyShape()
    }

    /// The theme's glass tint, its alpha scaled by the overlay tint
    /// strength tunable (1, the default, is the theme tint unchanged).
    private var overlayTint: NSColor {
        let tint = Palette.glassTint
        let strength = ChromeTunables.glassOverlayTintStrength.value
        guard strength != 1 else { return tint }
        return tint.withAlphaComponent(min(max(tint.alphaComponent * strength, 0), 1))
    }
}
