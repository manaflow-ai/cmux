public import AppKit
import ObjectiveC

/// One glass panel, whatever the OS: Liquid Glass (`NSGlassEffectView`) on
/// macOS 26 and later, and before it an `NSVisualEffectView` blur with the
/// same continuous corner radius, the same tint over it, and a hairline
/// edge. The API follows `NSGlassEffectView` (`contentView`,
/// `cornerRadius`, `tintColor`, `style`), and `contentView` is pinned to
/// the panel's edges with constraints on both paths, so content
/// constraints size the panel the same way. Made by `Glass.makePanel`.
@MainActor
public final class GlassPanelView: NSView {
    /// Whether this panel draws Liquid Glass (false: the older material).
    public let isLiquidGlass: Bool
    /// The view that draws the material: `NSGlassEffectView` or
    /// `NSVisualEffectView`.
    public let materialView: NSView
    /// The fallback's tint, between the blur and the content.
    private let tintView: NSView?

    /// The view drawn above the material, edge to edge.
    public var contentView: NSView? {
        didSet { if contentView !== oldValue { installContent(replacing: oldValue) } }
    }

    public var cornerRadius: CGFloat {
        didSet { if cornerRadius != oldValue { applyShape() } }
    }

    /// The tint over the material (nil: the material alone).
    public var tintColor: NSColor? {
        didSet { applyColors() }
    }

    public var style: Glass.Style {
        didSet { if style != oldValue { applyStyle() } }
    }

    /// The fallback blurs what is behind the window, not the window's own
    /// content: set it for a panel that is the whole content of a clear
    /// window (the drag ghost). Liquid Glass ignores it.
    public var samplesBehindWindow = false {
        didSet { applyStyle() }
    }

    /// Whether the glass keeps its key-window look while its window is not key
    /// (``ActiveLookGlassEffectView``); the fallback is always `.active`.
    public let keepsActiveLook: Bool

    /// `liquidGlass` picks the material; it defaults to this Mac's
    /// (`Glass.isLiquidGlassAvailable`). `keepsActiveLook` keeps the key
    /// window's glass when the window resigns key, as the fallback's
    /// `NSVisualEffectView.state = .active` does (the window backdrop).
    public init(style: Glass.Style = .regular, cornerRadius: CGFloat = 0, interactive: Bool = false,
                liquidGlass: Bool = Glass.isLiquidGlassAvailable, keepsActiveLook: Bool = false) {
        self.style = style
        self.cornerRadius = cornerRadius
        self.keepsActiveLook = keepsActiveLook
        if #available(macOS 26.0, *), liquidGlass {
            let glass = keepsActiveLook ? ActiveLookGlassEffectView() : NSGlassEffectView()
            Self.setInteractive(glass, interactive)
            isLiquidGlass = true
            materialView = glass
            tintView = nil
        } else {
            let effect = NSVisualEffectView()
            effect.state = .active
            effect.wantsLayer = true
            let tint = NSView()
            tint.wantsLayer = true
            tint.translatesAutoresizingMaskIntoConstraints = false
            effect.addSubview(tint)
            NSLayoutConstraint.activate(Self.edges(of: tint, to: effect))
            isLiquidGlass = false
            materialView = effect
            tintView = tint
        }
        super.init(frame: .zero)
        materialView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(materialView)
        NSLayoutConstraint.activate(Self.edges(of: materialView, to: self))
        applyStyle()
        applyShape()
        applyColors()
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        applyShape()
    }

    private func installContent(replacing old: NSView?) {
        if #available(macOS 26.0, *), let glass = materialView as? NSGlassEffectView {
            glass.contentView = contentView
            return
        }
        old?.removeFromSuperview()
        guard let contentView, let tintView else { return }
        // Like NSGlassEffectView: the content is laid out by constraints.
        contentView.translatesAutoresizingMaskIntoConstraints = false
        tintView.addSubview(contentView)
        NSLayoutConstraint.activate(Self.edges(of: contentView, to: tintView))
    }

    private func applyStyle() {
        if #available(macOS 26.0, *), let glass = materialView as? NSGlassEffectView {
            switch style {
            case .regular: glass.style = .regular
            case .clear: glass.style = .clear
            }
            return
        }
        guard let effect = materialView as? NSVisualEffectView else { return }
        effect.material = style == .clear ? .hudWindow : .popover
        effect.blendingMode = samplesBehindWindow ? .behindWindow : .withinWindow
    }

    private func applyShape() {
        if #available(macOS 26.0, *), let glass = materialView as? NSGlassEffectView {
            glass.cornerRadius = cornerRadius
            return
        }
        guard let layer = materialView.layer else { return }
        layer.cornerRadius = cornerRadius
        layer.cornerCurve = .continuous
        layer.masksToBounds = true
        layer.borderWidth = Metrics.lineWidth(1 / max(window?.backingScaleFactor ?? 2, 1))
    }

    /// Theme colors: the glass tint, or the fallback's tint and hairline.
    /// Never an accent color.
    private func applyColors() {
        if #available(macOS 26.0, *), let glass = materialView as? NSGlassEffectView {
            glass.tintColor = tintColor
            return
        }
        performWithTheme {
            tintView?.layer?.backgroundColor = tintColor?.cgColor
            materialView.layer?.borderColor = Palette.separator.cgColor
        }
    }

    /// `effectIsInteractive` is macOS 27 SDK only. Xcode 26.x (CI and fleet)
    /// lacks the symbol even inside `#available`, so it also needs a compiler
    /// guard (plans/cmux-next/shell.md section 3.3).
    @available(macOS 26.0, *)
    private static func setInteractive(_ glass: NSGlassEffectView, _ interactive: Bool) {
        #if compiler(>=6.4)
        if #available(macOS 27.0, *) {
            glass.effectIsInteractive = interactive
        }
        #endif
    }

    private static func edges(of view: NSView, to container: NSView) -> [NSLayoutConstraint] {
        [
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ]
    }
}

/// Liquid Glass that keeps its key-window look when its window resigns key (Leo, 2026-10-26: "i
/// didnt want any glass. you're frosting the app's background which is pointless?").
///
/// `NSGlassEffectView` has no public `state` like `NSVisualEffectView.state = .active`. When its
/// window resigns key, AppKit calls the view's private `_windowChangedKeyState`, and the glass drops
/// its `tintColor` and draws the system's inactive grey frost. This view lets that call through only
/// while its window is key, so it takes the active look when the window first becomes key and keeps
/// it after (measured on macOS 27 with a tinted glass window: key 0.69/0.50/0.38, not key with plain
/// `NSGlassEffectView` 0.18 grey, not key with this view 0.69/0.50/0.38, the key look). If AppKit
/// stops calling the hook, this changes nothing and the glass follows the key state again.
@available(macOS 26.0, *)
final class ActiveLookGlassEffectView: NSGlassEffectView {
    private static let keyStateChange = NSSelectorFromString("_windowChangedKeyState")

    /// Whether a key-state change reaches the glass: only into a key window.
    static func passesKeyStateChange(windowIsKey: Bool) -> Bool { windowIsKey }

    @objc(_windowChangedKeyState)
    func windowChangedKeyState() {
        guard Self.passesKeyStateChange(windowIsKey: window?.isKeyWindow == true) else { return }
        // The glass's own handler (NSView's when the glass has none of its own).
        guard let implementation = class_getMethodImplementation(NSGlassEffectView.self, Self.keyStateChange),
              NSGlassEffectView.instancesRespond(to: Self.keyStateChange) else { return }
        typealias Handler = @convention(c) (NSGlassEffectView, Selector) -> Void
        unsafeBitCast(implementation, to: Handler.self)(self, Self.keyStateChange)
    }
}
