public import AppKit
import Darwin
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

/// Liquid Glass that keeps its key-window look when its window is not key (Leo, 2026-10-26: "i
/// didnt want any glass. you're frosting the app's background which is pointless?").
///
/// `NSGlassEffectView` has no public `state` like `NSVisualEffectView.state = .active`. It draws
/// from a private SwiftUI graph whose environment it builds from its window, and the inactive grey
/// frost follows the window's `_hasActiveAppearanceIgnoringKeyFocus` read there. While this view
/// updates its subtree (``ActiveLookScope``), that one read answers true, so the glass keeps the
/// key look; every other read, including the glass's second read that the titlebar's traffic
/// lights follow, gets AppKit's answer. Measured on macOS 27.0.1, a glass window tinted
/// 0.85/0.45/0.2 at 0.55: key 0.689/0.504/0.378; another app active, plain glass 0.541 grey and
/// this view 0.689/0.504/0.378, with grey traffic lights as before. If AppKit stops reading it
/// there, nothing is forced and the glass follows the key state again.
@available(macOS 26.0, *)
final class ActiveLookGlassEffectView: NSGlassEffectView {
    override init(frame frameRect: NSRect) {
        ActiveLookScope.install()
        super.init(frame: frameRect)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() { ActiveLookScope.during { super.layout() } }
    override func updateConstraints() { ActiveLookScope.during { super.updateConstraints() } }
    override func viewWillDraw() { ActiveLookScope.during { super.viewWillDraw() } }
    override func viewDidMoveToWindow() { ActiveLookScope.during { super.viewDidMoveToWindow() } }
    override func viewDidChangeEffectiveAppearance() { ActiveLookScope.during { super.viewDidChangeEffectiveAppearance() } }

    // AppKit lays out and updates constraints for the subtree (the glass's own hosting view, where
    // the read happens) through these, not through the public methods above.
    @objc(_layoutSubtreeWithOldSize:)
    func layoutSubtree(withOldSize oldSize: NSSize) {
        typealias Method = @convention(c) (NSView, Selector, NSSize) -> Void
        let selector = NSSelectorFromString("_layoutSubtreeWithOldSize:")
        guard let implementation = Self.superImplementation(selector) else { return }
        ActiveLookScope.during { unsafeBitCast(implementation, to: Method.self)(self, selector, oldSize) }
    }

    @objc(_updateConstraintsForSubtreeIfNeededCollectingViewsWithInvalidBaselines:)
    func updateConstraintsForSubtree(collecting views: UnsafeMutableRawPointer?) {
        typealias Method = @convention(c) (NSView, Selector, UnsafeMutableRawPointer?) -> Void
        let selector = NSSelectorFromString("_updateConstraintsForSubtreeIfNeededCollectingViewsWithInvalidBaselines:")
        guard let implementation = Self.superImplementation(selector) else { return }
        ActiveLookScope.during { unsafeBitCast(implementation, to: Method.self)(self, selector, views) }
    }

    @objc(_windowChangedKeyState)
    func windowChangedKeyState() {
        typealias Method = @convention(c) (NSView, Selector) -> Void
        let selector = NSSelectorFromString("_windowChangedKeyState")
        guard let implementation = Self.superImplementation(selector) else { return }
        ActiveLookScope.during { unsafeBitCast(implementation, to: Method.self)(self, selector) }
    }

    /// The glass's own implementation (NSView's when it has none), or nil when AppKit has none.
    private static func superImplementation(_ selector: Selector) -> IMP? {
        NSGlassEffectView.instancesRespond(to: selector) ? class_getMethodImplementation(NSGlassEffectView.self, selector) : nil
    }
}

/// Which reads of `NSWindow._hasActiveAppearanceIgnoringKeyFocus` answer true: only the glass's
/// material read, and only while an ``ActiveLookGlassEffectView`` updates its subtree.
///
/// The glass's environment reads the window's active appearance twice in one pass: first for its
/// material (the frost), then for a state the titlebar's traffic lights follow. Forcing both kept
/// the traffic lights colored in an inactive window, so only the first call site seen inside the
/// scope (the material read; the code runs it before the other) is forced, and every read outside
/// the scope costs one integer check. Main thread only: AppKit lays out and draws there.
enum ActiveLookScope {
    /// How deep the updates of ``ActiveLookGlassEffectView``s nest now.
    nonisolated(unsafe) private static var depth = 0
    /// The return address of the glass's material read, learned from the first read in the scope.
    nonisolated(unsafe) private static var materialSite: UInt?
    nonisolated(unsafe) private static var installed = false

    static func during(_ body: () -> Void) {
        depth += 1
        defer { depth -= 1 }
        body()
    }

    /// Whether the read from `site` answers true (`depth` updates under way, `materialSite` the
    /// site learned so far, set by the first read inside the scope).
    static func forcesActive(depth: Int, site: UInt, materialSite: inout UInt?) -> Bool {
        guard depth > 0 else { return false }
        guard let known = materialSite else {
            materialSite = site
            return true
        }
        return site == known
    }

    /// Routes `NSWindow._hasActiveAppearanceIgnoringKeyFocus` through ``forcesActive``, once.
    @MainActor static func install() {
        guard !installed else { return }
        installed = true
        let selector = NSSelectorFromString("_hasActiveAppearanceIgnoringKeyFocus")
        guard let method = class_getInstanceMethod(NSWindow.self, selector) else { return }
        typealias Getter = @convention(c) (NSWindow, Selector) -> Bool
        let original = unsafeBitCast(method_getImplementation(method), to: Getter.self)
        let replacement: @convention(block) (NSWindow) -> Bool = { window in
            guard depth > 0, Thread.isMainThread, let site = reader() else { return original(window, selector) }
            return forcesActive(depth: depth, site: site, materialSite: &materialSite) || original(window, selector)
        }
        method_setImplementation(method, imp_implementationWithBlock(replacement))
    }

    /// The return address in the code that called the getter: the first frame outside this binary
    /// (the getter's block and its trampoline are in it).
    private static func reader() -> UInt? {
        var own = Dl_info()
        guard dladdr(#dsohandle, &own) != 0 else { return nil }
        for frame in Thread.callStackReturnAddresses.prefix(8) {
            var info = Dl_info()
            guard dladdr(UnsafeRawPointer(bitPattern: frame.uintValue), &info) != 0 else { continue }
            if info.dli_fbase != own.dli_fbase { return frame.uintValue }
        }
        return nil
    }
}
