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
/// updates its own subtree, ``ActiveLookScope`` answers that one read true for this view's window;
/// every other read (the graph's second one, which the traffic lights follow, and any read
/// outside the glass) gets AppKit's answer. Measured on macOS 27.0.1, a glass window tinted
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

    override func layout() { ActiveLookScope.during(window) { super.layout() } }
    override func updateConstraints() { ActiveLookScope.during(window) { super.updateConstraints() } }
    override func viewWillDraw() { ActiveLookScope.during(window) { super.viewWillDraw() } }
    override func viewDidMoveToWindow() { ActiveLookScope.during(window) { super.viewDidMoveToWindow() } }
    override func viewDidChangeEffectiveAppearance() { ActiveLookScope.during(window) { super.viewDidChangeEffectiveAppearance() } }

    // AppKit lays out and updates constraints for the subtree (the glass's own hosting view, where
    // the read happens) through these, not through the public methods above.
    @objc(_layoutSubtreeWithOldSize:)
    func layoutSubtree(withOldSize oldSize: NSSize) {
        typealias Method = @convention(c) (NSView, Selector, NSSize) -> Void
        let selector = NSSelectorFromString("_layoutSubtreeWithOldSize:")
        guard let implementation = Self.superImplementation(selector) else { return }
        ActiveLookScope.during(window) { unsafeBitCast(implementation, to: Method.self)(self, selector, oldSize) }
    }

    @objc(_updateConstraintsForSubtreeIfNeededCollectingViewsWithInvalidBaselines:)
    func updateConstraintsForSubtree(collecting views: UnsafeMutableRawPointer?) {
        typealias Method = @convention(c) (NSView, Selector, UnsafeMutableRawPointer?) -> Void
        let selector = NSSelectorFromString("_updateConstraintsForSubtreeIfNeededCollectingViewsWithInvalidBaselines:")
        guard let implementation = Self.superImplementation(selector) else { return }
        ActiveLookScope.during(window) { unsafeBitCast(implementation, to: Method.self)(self, selector, views) }
    }

    @objc(_windowChangedKeyState)
    func windowChangedKeyState() {
        typealias Method = @convention(c) (NSView, Selector) -> Void
        let selector = NSSelectorFromString("_windowChangedKeyState")
        guard let implementation = Self.superImplementation(selector) else { return }
        ActiveLookScope.during(window) { unsafeBitCast(implementation, to: Method.self)(self, selector) }
    }

    /// The glass's own implementation (NSView's when it has none), or nil when AppKit has none.
    private static func superImplementation(_ selector: Selector) -> IMP? {
        NSGlassEffectView.instancesRespond(to: selector) ? class_getMethodImplementation(NSGlassEffectView.self, selector) : nil
    }
}

/// Which reads of `NSWindow._hasActiveAppearanceIgnoringKeyFocus` answer true: only the glass's
/// material read, for the window whose ``ActiveLookGlassEffectView`` is updating its subtree.
///
/// A read is forced only when all of these hold: it is on the main thread; AppKit's own answer is
/// false (a key window costs nothing more); the receiver is the window of the innermost glass
/// update under way; the reader is AppKit code that a SwiftUI graph update called (the glass's
/// environment, not titlebar or other chrome, which AppKit calls from Objective-C methods); and
/// the read is the first of that graph's reads in code order. The graph reads the value twice, the
/// material first and then a state the traffic lights follow; forcing both colored the close
/// button of an inactive window, so the second read keeps AppKit's answer.
@MainActor
enum ActiveLookScope {
    /// The windows of the glass updates under way, innermost last.
    private static var windows: [ObjectIdentifier] = []
    /// Per reader return address: whether it is a SwiftUI graph's read in AppKit.
    private static var graphReaders: [UInt: Bool] = [:]
    /// The glass material's read: the lowest graph reader address seen in its function.
    private static var materialSite: (function: UInt, site: UInt)?
    private static var installed = false

    /// Runs `body`, a glass update for `window`, with that window's material read forced active.
    static func during(_ window: NSWindow?, _ body: () -> Void) {
        guard let window else { return body() }
        windows.append(ObjectIdentifier(window))
        defer { windows.removeLast() }
        body()
    }

    /// Learns the material site from graph read `site` in `function` and says whether to force it.
    /// The reads of one function are ordered by address, and the material read is its first, so a
    /// lower address seen later replaces a higher one; a read of another function is never forced.
    static func isMaterialRead(site: UInt, function: UInt, learned: inout (function: UInt, site: UInt)?) -> Bool {
        if let known = learned, known.function != function { return false }
        let material = min(learned?.site ?? site, site)
        learned = (function, material)
        return site == material
    }

    /// Routes `NSWindow._hasActiveAppearanceIgnoringKeyFocus` through the scope, once.
    static func install() {
        guard !installed else { return }
        installed = true
        let selector = NSSelectorFromString("_hasActiveAppearanceIgnoringKeyFocus")
        guard let method = class_getInstanceMethod(NSWindow.self, selector) else { return }
        let original = unsafeBitCast(method_getImplementation(method), to: Getter.self)
        method_setImplementation(method, imp_implementationWithBlock(replacement(original, selector)))
    }

    typealias Getter = @convention(c) (NSWindow, Selector) -> Bool

    /// The getter AppKit calls from any thread: off the main thread, or when AppKit already
    /// answers true, it touches nothing here.
    nonisolated private static func replacement(_ original: Getter, _ selector: Selector) -> @convention(block) (NSWindow) -> Bool {
        { window in
            let answer = original(window, selector)
            guard !answer, pthread_main_np() != 0 else { return answer }
            return MainActor.assumeIsolated { forces(window) }
        }
    }

    /// The window whose glass is updating now (tests read it).
    static var scopedWindow: ObjectIdentifier? { windows.last }

    private static func forces(_ window: NSWindow) -> Bool {
        guard windows.last == ObjectIdentifier(window) else { return false }
        // A bounded stack read: this block, then AppKit's reader, then its callers.
        var frames = [UnsafeMutableRawPointer?](repeating: nil, count: 12)
        let count = Int(frames.withUnsafeMutableBufferPointer { backtrace($0.baseAddress, 12) })
        guard let reader = readerIndex(in: frames, count: count), let address = frames[reader].map({ UInt(bitPattern: $0) }) else {
            return false
        }
        let isGraphRead: Bool
        if let known = graphReaders[address] {
            isGraphRead = known
        } else {
            isGraphRead = image(of: frames[reader]) == appKitImage && frames[(reader + 1)..<count].contains { isSwiftUI(image(of: $0)) }
            graphReaders[address] = isGraphRead
        }
        guard isGraphRead, let function = functionStart(of: frames[reader]) else { return false }
        return isMaterialRead(site: address, function: function, learned: &materialSite)
    }

    /// The first frame outside this binary: AppKit code that read the getter.
    private static func readerIndex(in frames: [UnsafeMutableRawPointer?], count: Int) -> Int? {
        let own = ownImage
        return (0..<count).first { image(of: frames[$0]).map { $0 != own } ?? false }
    }

    private static let ownImage: UnsafeMutableRawPointer? = {
        var info = Dl_info()
        return dladdr(#dsohandle, &info) != 0 ? info.dli_fbase : nil
    }()

    private static let appKitImage: UnsafeMutableRawPointer? = {
        var info = Dl_info()
        let layout = class_getMethodImplementation(NSView.self, #selector(NSView.layout))
        return dladdr(unsafeBitCast(layout, to: UnsafeRawPointer.self), &info) != 0 ? info.dli_fbase : nil
    }()

    private static var imageNames: [UnsafeMutableRawPointer: String] = [:]

    private static func image(of frame: UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer? {
        var info = Dl_info()
        guard let frame, dladdr(frame, &info) != 0, let base = info.dli_fbase else { return nil }
        if imageNames[base] == nil, let name = info.dli_fname { imageNames[base] = String(cString: name) }
        return base
    }

    private static func isSwiftUI(_ base: UnsafeMutableRawPointer?) -> Bool {
        guard let base, let name = imageNames[base] else { return false }
        return name.hasSuffix("/SwiftUICore") || name.hasSuffix("/SwiftUI")
    }

    private static func functionStart(of frame: UnsafeMutableRawPointer?) -> UInt? {
        var info = Dl_info()
        guard let frame, dladdr(frame, &info) != 0, let start = info.dli_saddr else { return nil }
        return UInt(bitPattern: start)
    }
}
