public import AppKit

/// A view the host can use as one surface's glass: anything that can be rounded. ``GlassMaterialView``
/// is the default; an app with its own material (its own tint, rim or theme) conforms its view.
@MainActor
public protocol GlassSurfaceView: NSView {
    var cornerRadius: CGFloat { get set }
}

/// The system's glass for one surface, following the Mac it runs on: Liquid Glass
/// (`NSGlassEffectView`) on macOS 26 and later, the vibrancy blur (`NSVisualEffectView`) in the
/// level's system material before it, and an opaque fill under Reduce Transparency. It takes no
/// clicks: the page above it does.
@MainActor
public final class GlassMaterialView: NSView, GlassSurfaceView {
    /// How the material is drawn now.
    public enum Material: Equatable, Sendable {
        case liquidGlass
        case vibrancy
        case opaque

        /// The material for an OS with (or without) Liquid Glass under the Reduce Transparency setting.
        public static func select(liquidGlass: Bool, reduceTransparency: Bool) -> Material {
            if reduceTransparency { return .opaque }
            return liquidGlass ? .liquidGlass : .vibrancy
        }

        /// This Mac's material now.
        public static var current: Material {
            select(liquidGlass: ProcessInfo.processInfo.isOperatingSystemAtLeast(
                       OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0)),
                   reduceTransparency: NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency)
        }
    }

    public let level: GlassLevel
    public private(set) var material: Material
    /// A tint laid on the glass (Liquid Glass's own `tintColor`; a layer over the blur before it).
    /// Nil draws the system's glass as is.
    public var tintColor: NSColor? {
        didSet { applyTint() }
    }

    public var cornerRadius: CGFloat = 0 {
        didSet { if cornerRadius != oldValue { applyShape() } }
    }

    private var materialView: NSView?
    private var tintView: NSView?
    /// Set once in init and read only by deinit; NotificationCenter's removeObserver is thread-safe, so a
    /// deinit on any thread may remove it (macOS 14 has no isolated deinit).
    private nonisolated(unsafe) var observer: (any NSObjectProtocol)?

    /// `material` pins one (tests, previews); nil follows this Mac and its Reduce Transparency setting live.
    public init(level: GlassLevel, material: Material? = nil) {
        self.level = level
        self.material = material ?? .current
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        setAccessibilityElement(false)
        rebuild()
        if material == nil {
            observer = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshMaterial() }
            }
        }
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit {
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }

    public override func hitTest(_ point: NSPoint) -> NSView? { nil }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        if material == .opaque { layer?.backgroundColor = Self.opaqueFill(for: effectiveAppearance) }
    }

    /// Reads this Mac's material again (Reduce Transparency changed).
    public func refreshMaterial() {
        let next = Material.current
        guard next != material else { return }
        material = next
        rebuild()
    }

    /// The vibrancy material each level draws before Liquid Glass.
    public static func systemMaterial(_ level: GlassLevel) -> NSVisualEffectView.Material {
        switch level {
        case .popover: .popover
        case .menu: .menu
        case .chip: .toolTip
        }
    }

    private func rebuild() {
        materialView?.removeFromSuperview()
        tintView?.removeFromSuperview()
        materialView = nil
        tintView = nil
        layer?.backgroundColor = nil
        switch material {
        case .liquidGlass:
            if #available(macOS 26.0, *) {
                let glass = NSGlassEffectView()
                add(glass)
                materialView = glass
            } else {
                addVibrancy()
            }
        case .vibrancy:
            addVibrancy()
        case .opaque:
            layer?.backgroundColor = Self.opaqueFill(for: effectiveAppearance)
        }
        applyShape()
        applyTint()
    }

    private func addVibrancy() {
        let effect = NSVisualEffectView()
        effect.state = .active
        effect.material = Self.systemMaterial(level)
        // The page and its window are what is behind the surface.
        effect.blendingMode = .withinWindow
        add(effect)
        materialView = effect
        let tint = NSView()
        tint.wantsLayer = true
        add(tint)
        tintView = tint
    }

    private func add(_ view: NSView) {
        view.frame = bounds
        view.autoresizingMask = [.width, .height]
        addSubview(view)
    }

    private func applyShape() {
        layer?.cornerRadius = cornerRadius
        layer?.cornerCurve = .continuous
        if #available(macOS 26.0, *), let glass = materialView as? NSGlassEffectView {
            glass.cornerRadius = cornerRadius
        }
    }

    private func applyTint() {
        if #available(macOS 26.0, *), let glass = materialView as? NSGlassEffectView {
            glass.tintColor = tintColor
            return
        }
        tintView?.layer?.backgroundColor = tintColor?.cgColor
    }

    private static func opaqueFill(for appearance: NSAppearance) -> CGColor {
        var color = NSColor.windowBackgroundColor.cgColor
        appearance.performAsCurrentDrawingAppearance { color = NSColor.windowBackgroundColor.cgColor }
        return color
    }
}
