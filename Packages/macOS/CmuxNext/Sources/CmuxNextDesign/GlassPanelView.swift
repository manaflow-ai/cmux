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
    /// (`Glass.isLiquidGlassAvailable`). `activeLook`, the app's one ``ActiveLookScope``, keeps the
    /// key window's glass when the window resigns key, as the fallback's
    /// `NSVisualEffectView.state = .active` does (the window backdrop); nil follows the key state.
    public init(style: Glass.Style = .regular, cornerRadius: CGFloat = 0, interactive: Bool = false,
                liquidGlass: Bool = Glass.isLiquidGlassAvailable, activeLook: ActiveLookScope? = nil) {
        self.style = style
        self.cornerRadius = cornerRadius
        keepsActiveLook = activeLook != nil
        if #available(macOS 26.0, *), liquidGlass {
            let glass: NSGlassEffectView = activeLook.map { ActiveLookGlassEffectView(scope: $0) } ?? NSGlassEffectView()
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
/// frost follows the window's `_hasActiveAppearanceIgnoringKeyFocus` read there. Its ``ActiveLookScope``
/// finds that one read while this view updates its own subtree, then answers it true for every
/// glass graph in a window that holds this view: Liquid Glass draws a window's glass together, and
/// AppKit re-renders those graphs from many paths (the display cycle, key and appearance changes,
/// the theme repaint), so a scope around this view's updates alone left the frost on a fleet mini
/// most of the time. Every other read (the graph's second one, which the traffic lights follow, and
/// any read outside a glass graph) gets AppKit's answer. Measured on macOS 27.0.1, a glass window
/// tinted 0.85/0.45/0.2 at 0.55: key 0.689/0.504/0.378; another app active, plain glass 0.541 grey
/// and this view 0.689/0.504/0.378, with grey traffic lights as before. If AppKit stops reading it
/// there, nothing is forced and the glass follows the key state again.
@available(macOS 26.0, *)
final class ActiveLookGlassEffectView: NSGlassEffectView {
    /// The app's one scope (its composition root makes it), which this view's updates feed.
    private let scope: ActiveLookScope

    init(scope: ActiveLookScope) {
        self.scope = scope
        scope.install()
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() { scope.during(window) { super.layout() } }
    override func updateConstraints() { scope.during(window) { super.updateConstraints() } }
    override func viewWillDraw() { scope.during(window) { super.viewWillDraw() } }
    /// The window this view counts in (``ActiveLookScope/attach(to:)``), while it is in one.
    private weak var countedWindow: NSWindow?

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if let countedWindow, countedWindow !== newWindow {
            scope.detach(from: countedWindow)
            self.countedWindow = nil
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        if let window, countedWindow !== window {
            scope.attach(to: window)
            countedWindow = window
        }
        scope.during(window) { super.viewDidMoveToWindow() }
    }
    override func viewDidChangeEffectiveAppearance() { scope.during(window) { super.viewDidChangeEffectiveAppearance() } }

    // AppKit lays out and updates constraints for the subtree (the glass's own hosting view, where
    // the read happens) through these, not through the public methods above.
    @objc(_layoutSubtreeWithOldSize:)
    func layoutSubtree(withOldSize oldSize: NSSize) {
        typealias Method = @convention(c) (NSView, Selector, NSSize) -> Void
        let selector = NSSelectorFromString("_layoutSubtreeWithOldSize:") // crash-allow: AppKit private selector, called only when NSGlassEffectView responds to it (superImplementation)
        guard let implementation = Self.superImplementation(selector) else { return }
        scope.during(window) { unsafeBitCast(implementation, to: Method.self)(self, selector, oldSize) }
    }

    @objc(_updateConstraintsForSubtreeIfNeededCollectingViewsWithInvalidBaselines:)
    func updateConstraintsForSubtree(collecting views: UnsafeMutableRawPointer?) {
        typealias Method = @convention(c) (NSView, Selector, UnsafeMutableRawPointer?) -> Void
        let selector = NSSelectorFromString("_updateConstraintsForSubtreeIfNeededCollectingViewsWithInvalidBaselines:") // crash-allow: AppKit private selector, called only when NSGlassEffectView responds to it (superImplementation)
        guard let implementation = Self.superImplementation(selector) else { return }
        scope.during(window) { unsafeBitCast(implementation, to: Method.self)(self, selector, views) }
    }

    @objc(_windowChangedKeyState)
    func windowChangedKeyState() {
        typealias Method = @convention(c) (NSView, Selector) -> Void
        let selector = NSSelectorFromString("_windowChangedKeyState") // crash-allow: AppKit private selector, called only when NSGlassEffectView responds to it (superImplementation)
        guard let implementation = Self.superImplementation(selector) else { return }
        scope.during(window) { unsafeBitCast(implementation, to: Method.self)(self, selector) }
    }

    /// The glass's own implementation (NSView's when it has none), or nil when AppKit has none.
    private static func superImplementation(_ selector: Selector) -> IMP? {
        NSGlassEffectView.instancesRespond(to: selector) ? class_getMethodImplementation(NSGlassEffectView.self, selector) : nil
    }
}

/// Which reads of `NSWindow._hasActiveAppearanceIgnoringKeyFocus` answer true: only the glass
/// graphs' material read, in a window that holds an ``ActiveLookGlassEffectView``.
///
/// The glass's private SwiftUI graph builds its environment in one AppKit function that reads the
/// value twice: the material first, then a state the traffic lights follow (forcing both colored
/// the close button of an inactive window). The scope finds that read by watching, and forces
/// nothing while it watches:
///
/// 1. Calibration, which never forces anything (every read keeps AppKit's answer): each read
///    inside a glass update for its own window, made by AppKit code with a SwiftUI frame above it
///    in the same call, is recorded with its site (the return address in the reader) and its
///    caller. When the outermost update ends, a caller with exactly two sites that is the only
///    caller with reads is a candidate pair. The same pair from ``confirmations`` updates in a row
///    fixes the material site: the lower of the two, the earlier in code. Any other outcome
///    resets the count. The glass's first layout, as its window comes on screen, is such an
///    update, so a new window is calibrated before it can lose focus.
/// 2. After that, a read is forced only when its site is exactly that instruction and its window
///    holds an ``ActiveLookGlassEffectView`` now (``attach(to:)``), wherever the read comes
///    from. Every other read, and every read off the main thread, keeps AppKit's answer. Until
///    calibration ends the glass follows the key state.
///
/// The getter hook is process-wide, so the app has one scope: its composition root (`AppServices`)
/// makes it and passes it to every window (`NSWindow.install(kind:content:scope:activeLook:)`).
/// The hook is installed once per process and captures the first scope whose
/// ``ActiveLookGlassEffectView`` installs it; a later scope (a test's) never stacks a second hook.
@MainActor
public final class ActiveLookScope {
    /// One calibration read: where in AppKit it was, and the return address of its caller.
    struct Read: Hashable {
        let site: UInt
        let caller: UInt
    }

    /// Updates in a row that must agree on the pair before its material site is used. One: a
    /// window loses focus after its first layout as often as not (the fleet probe calibrated only
    /// at its first app switch with two), and the pair's shape (one AppKit caller, exactly two
    /// sites, under a SwiftUI update in the glass's own subtree) is the check.
    static let confirmations = 1

    /// The windows of the glass updates under way, innermost last.
    private var windows: [ObjectIdentifier] = []
    /// The calibration reads of the outermost update under way.
    private var pending: [Read] = []
    /// The candidate pair and how many updates in a row agreed on it.
    private var candidate: (pair: [UInt], count: Int)?
    /// The material read's site, once calibration ended.
    private(set) var materialSite: UInt?
    private var installed = false

    public init() {}
    /// Frames read per check: the reader, its caller and the SwiftUI frames above them (3 to 6
    /// frames up in the fleet traces).
    private static let depth = 32

    /// Runs `body`, a glass update for `window`, with that window's material read forced active.
    func during(_ window: NSWindow?, _ body: () -> Void) {
        guard let window else { return body() }
        windows.append(ObjectIdentifier(window))
        defer {
            windows.removeLast()
            if windows.isEmpty, materialSite == nil { finishCalibration() }
        }
        body()
    }

    /// The window whose glass is updating now (tests read it).
    var scopedWindow: ObjectIdentifier? { windows.last }

    /// The pair `reads` (one update's calibration reads) show: the two sites of their only caller,
    /// ascending, or nil when they show anything else.
    static func pair(in reads: [Read]) -> [UInt]? {
        let callers = Set(reads.map(\.caller))
        guard callers.count == 1 else { return nil }
        let sites = Set(reads.map(\.site))
        return sites.count == 2 ? sites.sorted() : nil
    }

    /// Folds one update's `pair` into `candidate`; returns the material site once `confirmations`
    /// updates in a row agreed.
    static func confirm(_ pair: [UInt]?, candidate: inout (pair: [UInt], count: Int)?) -> UInt? {
        guard let pair else {
            candidate = nil
            return nil
        }
        let count = candidate?.pair == pair ? (candidate?.count ?? 0) + 1 : 1
        candidate = (pair, count)
        return count >= confirmations ? pair.first : nil
    }

    private func finishCalibration() {
        defer { pending.removeAll() }
        // An update with no calibration reads (no graph update) says nothing.
        guard !pending.isEmpty else { return }
        materialSite = Self.confirm(Self.pair(in: pending), candidate: &candidate)
    }

    /// Routes `NSWindow._hasActiveAppearanceIgnoringKeyFocus` through this scope, once per process;
    /// the hook captures the scope. The swizzle is process-wide, so its once lives where it does, in
    /// the runtime: a marker method on NSWindow that only the first install can add. A second hook
    /// would wrap the first and push the reader past ``forcingDepth``.
    func install() {
        guard !installed else { return }
        installed = true
        let marker = NSSelectorFromString("cmux_activeLookScopeInstalled") // crash-allow: our own marker selector, added with class_addMethod and never called
        let markerBody: @convention(block) (NSWindow) -> Bool = { _ in true }
        guard class_addMethod(NSWindow.self, marker, imp_implementationWithBlock(markerBody), "B@:") else { return }
        let selector = NSSelectorFromString("_hasActiveAppearanceIgnoringKeyFocus") // crash-allow: AppKit private getter, swizzled only when class_getInstanceMethod finds it
        guard let method = class_getInstanceMethod(NSWindow.self, selector) else { return }
        let original = unsafeBitCast(method_getImplementation(method), to: Getter.self)
        method_setImplementation(method, imp_implementationWithBlock(replacement(original, selector)))
    }

    typealias Getter = @convention(c) (NSWindow, Selector) -> Bool

    /// The getter AppKit calls from any thread: off the main thread it touches nothing here.
    nonisolated private func replacement(_ original: Getter, _ selector: Selector) -> @convention(block) (NSWindow) -> Bool {
        { [self] window in
            let answer = original(window, selector)
            guard pthread_main_np() != 0 else { return answer }
            return MainActor.assumeIsolated { decide(window, answer: answer) } // main-proof: pthread_main_np() checked on the line above
        }
    }

    private func decide(_ window: NSWindow, answer: Bool) -> Bool {
        if let materialSite {
            // Calibrated: only an inactive answer in an active-look window can change.
            guard !answer, keepsActiveLook(window) else { return answer }
            return reader(depth: Self.forcingDepth) == materialSite
        }
        // Calibrating: only reads inside a glass update for this window count.
        guard windows.last == ObjectIdentifier(window) else { return answer }
        var frames = [UnsafeMutableRawPointer?](repeating: nil, count: Self.depth)
        let count = Int(frames.withUnsafeMutableBufferPointer { backtrace($0.baseAddress, Int32(Self.depth)) })
        // The reader: the first AppKit frame (below it only this getter and its Swift thunks).
        guard let reader = (0..<count).first(where: { kind(of: frames[$0]) == .appKit }), reader + 1 < count,
              frames[(reader + 1)..<count].contains(where: { kind(of: $0) == .swiftUI }),
              let site = frames[reader].map({ UInt(bitPattern: $0) }) else { return answer }
        if let caller = frames[reader + 1].map({ UInt(bitPattern: $0) }) { pending.append(Read(site: site, caller: caller)) }
        return answer
    }

    /// Frames read to find a calibrated read's site: the getter, its Swift thunks and the reader
    /// sit within the first dozen.
    private static let forcingDepth = 16

    /// The current read's site: the first AppKit frame in the innermost `depth` frames, or nil.
    private func reader(depth: Int) -> UInt? {
        var frames = [UnsafeMutableRawPointer?](repeating: nil, count: depth)
        let count = Int(frames.withUnsafeMutableBufferPointer { backtrace($0.baseAddress, Int32(depth)) })
        guard let reader = frames[0..<count].first(where: { kind(of: $0) == .appKit }), let reader else { return nil }
        return UInt(bitPattern: reader)
    }

    /// How many ``ActiveLookGlassEffectView``s each window holds; a closed window drops out on its own.
    private let counts = NSMapTable<NSWindow, NSNumber>.weakToStrongObjects()

    /// Counts an ``ActiveLookGlassEffectView`` into `window`: while any is in it, the material read
    /// of every glass graph in it answers active. Liquid Glass renders a window's glass together: a
    /// fleet run that left the window's plain glass (composer, header) to AppKit's answer drew the
    /// frost over the backdrop again in 3 of 4 runs.
    func attach(to window: NSWindow) {
        setCount(count(window) + 1, window)
    }

    /// Counts one out of `window`; at zero its glass follows the key state again (a backdrop that
    /// switched to an opaque or frosted material, or moved to another window).
    func detach(from window: NSWindow) {
        setCount(max(count(window) - 1, 0), window)
    }

    /// Whether an ``ActiveLookGlassEffectView`` is in `window` now.
    func keepsActiveLook(_ window: NSWindow) -> Bool { count(window) > 0 }

    private func count(_ window: NSWindow) -> Int {
        counts.object(forKey: window)?.intValue ?? 0
    }

    private func setCount(_ count: Int, _ window: NSWindow) {
        if count == 0 { counts.removeObject(forKey: window) } else { counts.setObject(NSNumber(value: count), forKey: window) }
    }

    /// What a frame's image is: AppKit, SwiftUI (or SwiftUICore), or anything else.
    enum ImageKind { case appKit, swiftUI, other }

    /// The kind of each return address seen: code never moves while its image is loaded.
    private var kinds: [UnsafeMutableRawPointer: ImageKind] = [:]

    private func kind(of frame: UnsafeMutableRawPointer?) -> ImageKind {
        guard let frame else { return .other }
        if let known = kinds[frame] { return known }
        var info = Dl_info()
        let path = dladdr(frame, &info) != 0 ? info.dli_fname.map { String(cString: $0) } ?? "" : ""
        let kind = Self.imageKind(path: path)
        kinds[frame] = kind
        return kind
    }

    /// The kind of the image at `path` (tests read it).
    static func imageKind(path: String) -> ImageKind {
        if path.hasSuffix("/AppKit.framework/Versions/C/AppKit") || path.hasSuffix("/AppKit.framework/AppKit") { return .appKit }
        if path.hasSuffix("/SwiftUICore") || path.hasSuffix("/SwiftUI") { return .swiftUI }
        return .other
    }
}
