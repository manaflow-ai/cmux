import AppKit
import CmuxNextDesign

/// The fork's in-tree page calls (fork API 36, `include/cef_cmux.h` "In-tree pages"), resolved as optional shim
/// symbols: nil on an older engine, where the mode stays inert (``InTreePages/engineResolved(_:)``). Every name the
/// app uses lives here, so a rename touches one place.
struct CEFInTreeCalls {
    /// The shim's symbol names.
    nonisolated enum Symbol {
        static let setInTreeHosting = "cmux_shim_browser_set_in_tree_hosting"
        static let contentView = "cmux_shim_browser_in_tree_content_view"
        static let widgetDrawing = "cmux_shim_browser_in_tree_widget_drawing"
    }

    /// The first fork API with the in-tree calls.
    nonisolated static let forkAPI: Int32 = 36

    /// Puts the page into `container` (its `WebContentsViewCocoa` as the container's bottom subview) and returns the
    /// page's view; nil when the fork refused. A nil container ends it.
    let setInTreeHosting: (_ browser: Int32, _ container: NSView?) -> NSView?
    /// The current main-frame `RenderWidgetHostViewCocoa`; it changes with the renderer, so it is read each time.
    let contentView: (_ browser: Int32) -> NSView?
    /// 0: the headless widget's compositor is stopped; 1: it still draws; -1: not in tree.
    let widgetDrawing: (_ browser: Int32) -> Int32
    /// The window resize fence (``CEFLayerHosting/Fork/resizeFence``), nil when the engine lacks it.
    let resizeFence: ((_ browser: Int32, _ port: mach_port_t, _ timeoutMs: Int32,
                       _ done: @escaping @MainActor (Bool) -> Void) -> Bool)?

    init(setInTreeHosting: @escaping (_ browser: Int32, _ container: NSView?) -> NSView?,
         contentView: @escaping (_ browser: Int32) -> NSView?,
         widgetDrawing: @escaping (_ browser: Int32) -> Int32 = { _ in 0 },
         resizeFence: ((_ browser: Int32, _ port: mach_port_t, _ timeoutMs: Int32,
                        _ done: @escaping @MainActor (Bool) -> Void) -> Bool)? = nil) {
        self.setInTreeHosting = setInTreeHosting
        self.contentView = contentView
        self.widgetDrawing = widgetDrawing
        self.resizeFence = resizeFence
    }

    /// The shim's calls; nil without a shim, below fork API 36, or when a symbol is missing.
    init?(shim: CEFShimLibrary?, apiVersion: Int32) {
        guard Self.support(shim: shim, apiVersion: apiVersion) == .supported, let shim,
              let set = shim.browserSetInTreeHosting, let view = shim.browserInTreeContentView else { return nil }
        let drawing = shim.browserInTreeWidgetDrawing
        setInTreeHosting = { browser, container in
            set(browser, container.map { Unmanaged.passUnretained($0).toOpaque() })
                .map { Unmanaged<NSView>.fromOpaque($0).takeUnretainedValue() }
        }
        contentView = { browser in view(browser).map { Unmanaged<NSView>.fromOpaque($0).takeUnretainedValue() } }
        widgetDrawing = { browser in drawing?(browser) ?? -1 }
        resizeFence = CEFLayerHosting.Fork(shim: shim, apiVersion: apiVersion)?.resizeFence
    }

    /// Whether an engine can host pages in the tree, and why not.
    static func support(shim: CEFShimLibrary?, apiVersion: Int32) -> InTreePages.Engine {
        guard let shim else { return .unsupported("no engine") }
        guard apiVersion >= forkAPI else { return .unsupported("fork API \(apiVersion) < \(forkAPI)") }
        guard shim.browserSetInTreeHosting != nil, shim.browserInTreeContentView != nil else {
            return .unsupported("shim lacks \(Symbol.setInTreeHosting)")
        }
        return .supported
    }
}

/// The view in a ``CEFHostView`` that holds the in-tree page (the fork adds the page's `WebContentsViewCocoa` as its
/// bottom subview). The window's focus gate knows a page view by this container (``InTreePageContainer``), never by a
/// Chromium class name.
///
/// It clips the page to the pane's page area, and pins its content to the top-left corner: when a page's frame at a new
/// size misses the resize fence, its last frame shows clipped at the top-left until the new one comes, never stretched.
///
/// Its frame is whole points, pinned to the host's top-left corner (``wholePointFrame(in:flipped:)``): Chromium sizes a
/// page in whole points (a `RenderWidgetHostViewCocoa` reports its bounds as an integer `gfx::Rect`, its frames are
/// floored DIP sizes), and panes take half-point sizes, so a half-point page view and Chromium's size could differ by up
/// to a point (the viewport a point off its pane). With a whole-point container they are equal by construction; at most
/// the host's last point on the right and bottom shows its backdrop.
final class CEFInTreePageView: NSView, InTreePageContainer {
    /// The page's census, from its hosting (set by ``CEFInTreeHosting``).
    var census: () -> (contentInWindow: Bool, widgetDrawing: Int) = { (false, -1) }
    var inTreeCensus: InTreePageCensus {
        let now = census()
        return InTreePageCensus(contentInWindow: now.contentInWindow, widgetDrawing: now.widgetDrawing)
    }

    /// Where the page shows none of its pixels (the New Tab page's hole, ``CEFPageHole``): the window backdrop shows
    /// there, and a press there goes to the host view (``hitTest(_:)``).
    var hole: CEFPageHole = .none {
        didSet { if hole != oldValue { applyHole() } }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        autoresizingMask = [.width, .height]
        clipsToBounds = true
        layer?.masksToBounds = true
        layer?.contentsGravity = .topLeft
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        switch hole {
        case .whole: return nil
        case .rect(let rect) where rect.contains(local): return nil
        default: return super.hitTest(point)
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if case .rect = hole { applyHole() }
    }

    /// The host resized: the page takes its whole-point frame (never AppKit's autoresized half points).
    override func resize(withOldSuperviewSize oldSize: NSSize) {
        guard let superview else { return super.resize(withOldSuperviewSize: oldSize) }
        let fitted = Self.wholePointFrame(in: superview.bounds, flipped: superview.isFlipped)
        if frame != fitted { frame = fitted }
    }

    /// The container's frame in a host with `bounds`: whole-point width and height (rounded down, so the page never
    /// overhangs its pane), its top-left corner on the host's.
    nonisolated static func wholePointFrame(in bounds: NSRect, flipped: Bool) -> NSRect {
        let width = max(0, bounds.width.rounded(.down))
        let height = max(0, bounds.height.rounded(.down))
        let y = flipped ? bounds.minY : bounds.maxY - height
        return NSRect(x: bounds.minX, y: y, width: width, height: height)
    }

    private func applyHole() {
        guard let layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        switch hole {
        case .none:
            layer.mask = nil
        case .whole:
            layer.mask = CALayer()
        case .rect(let rect):
            let mask = layer.mask as? CAShapeLayer ?? CAShapeLayer()
            mask.frame = layer.bounds
            let path = CGMutablePath()
            path.addRect(layer.bounds)
            path.addRect(rect)
            mask.path = path
            mask.fillRule = .evenOdd
            layer.mask = mask
        }
    }
}

/// In-tree hosting of the page over one ``CEFHostView`` (fork API 36): the page's own view is a subview of the host,
/// in the cmux window, and draws itself. Its page window is headless; no layer hosting, detached hosting or resize
/// sync runs for it.
///
/// Like ``CEFLayerHosting``, a new page window's request runs at the end of the run-loop turn (the fork has no page
/// window inside Chromium's creation stack), and a refusal retries once, at the next show or the end of the next turn,
/// whichever comes first. A second refusal hands the
/// page back to layer hosting (`fallBack`), so a page never shows blank.
///
/// Tests drive it through ``CEFInTreeCalls`` and the `schedule` seam, without Chromium.
final class CEFInTreeHosting {
    weak var view: CEFHostView?
    /// The page container, made on the first request and kept for the host's life.
    private(set) var container: CEFInTreePageView?
    /// The page's view as the fork returned it (its `WebContentsViewCocoa`); nil while not in tree.
    private(set) var page: NSView?
    private(set) var browser: Int32?
    private var calls: CEFInTreeCalls?
    private var retryArmed = false
    private var scheduled = false
    /// The fork refused this host's page twice: the page went back to its own window (layer hosting).
    private(set) var fellBack = false
    /// Requests the fork refused (`debug.cef` `tracker.in_tree_refused`).
    private(set) var refusals = 0
    private let schedule: CEFLayerHosting.Scheduler
    private let resizeFences: CEFResizeFences
    /// The page goes back to layer hosting after a second refusal.
    var fallBack: (() -> Void)?
    /// Whether this host's pages may go in the tree; a host that sets it false keeps layer hosting. Every host is
    /// allowed: docked DevTools and `window.open` popups go in tree too since the fork draws a page that enters the
    /// tree at full size (cef#48 `cmux_in_tree_display`, dist 36g; before it they drew nothing).
    var isAllowed = true
    /// The page came into the tree: a focus ask kept while it was not in tree is granted now.
    var onAttached: (() -> Void)?

    init(schedule: @escaping CEFLayerHosting.Scheduler = { CEFLayerHosting.atEndOfTurn($0) },
         resizeFences: CEFResizeFences? = nil) {
        self.schedule = schedule
        self.resizeFences = resizeFences ?? CEFRuntime.shared.resizeFences
    }

    /// Whether the page is in the tree now.
    var isInTree: Bool { page != nil }

    /// A new page window over the view; `calls` nil: the engine has no in-tree calls.
    /// - Returns: Whether in-tree hosting owns this page window (the caller then gives layer hosting no fork).
    @discardableResult
    func pageWindowCreated(browser: Int32, calls: CEFInTreeCalls?) -> Bool {
        end()
        guard let calls, isAllowed, InTreePages.shared.isActive else { return false }
        fellBack = false
        self.browser = browser
        self.calls = calls
        retryArmed = false
        request()
        return true
    }

    /// A tab of the page window shows: an armed retry runs; a page whose content view left the container (a tab
    /// activation moved Chromium's contents view) is put back.
    func pageShown(browser: Int32) { // perf-hot: 10ms tab-switch (every Chromium tab show)
        guard let calls else { return }
        self.browser = browser
        if retryArmed {
            retryArmed = false
            return attach(retry: true)
        }
        guard let container, page != nil else { return }
        let content = calls.contentView(browser)
        if let content, !content.isDescendant(of: container) { return attach(retry: true) }
    }

    /// The page window's tabs changed; a live one names the window from now on.
    func windowBrowsersChanged(_ browsers: [Int32]) {
        guard let browser, !browsers.contains(browser) else { return }
        self.browser = browsers.first
    }

    /// The host view goes away or its page window closed: the page leaves the tree.
    func stop() {
        end()
    }

    private func end() {
        scheduled = false
        retryArmed = false
        if page != nil, let browser, let calls { _ = calls.setInTreeHosting(browser, nil) }
        page = nil
        browser = nil
        calls = nil
    }

    private func request() {
        scheduled = true
        schedule { [weak self] in
            guard let self, self.scheduled else { return }
            self.scheduled = false
            self.attach(retry: false)
        }
    }

    private func attach(retry: Bool) {
        guard let view, let browser, let calls else { return }
        let container = self.container ?? makeContainer(in: view)
        if let page = calls.setInTreeHosting(browser, container) {
            let was = self.page
            self.page = page
            CEFHostView.trackerStats.inTreeAttaches += 1
            if was == nil { onAttached?() }
            return
        }
        refusals += 1
        CEFHostView.trackerStats.inTreeRefused += 1
        page = nil
        if retry {
            // Refused twice: the page keeps its own window, hosted in the layer tree as before.
            self.calls = nil
            fellBack = true
            fallBack?()
        } else {
            // The retry comes at the next show, or at the end of the next run-loop turn when no show comes first: a
            // host Chromium never shows again (a docked DevTools' own host view) waited for a show forever, its page
            // blank, never falling back (live step 0c505ae5: DevTools drew 3 colours, hosted 0 pages, in tree).
            retryArmed = true
            schedule { [weak self] in
                guard let self, self.retryArmed else { return }
                self.retryArmed = false
                self.attach(retry: true)
            }
        }
    }

    private func makeContainer(in view: CEFHostView) -> CEFInTreePageView {
        let made = CEFInTreePageView(frame: CEFInTreePageView.wholePointFrame(in: view.bounds, flipped: view.isFlipped))
        made.census = { [weak self, weak made] in
            guard let self, let made else { return (false, -1) }
            let content = self.contentView
            return (content != nil && content?.window === made.window, Int(self.widgetDrawing ?? -1))
        }
        made.hole = view.layerHosting.pageHole
        // Below every other subview of the host (the tracker's probe), as the hosted page was.
        view.addSubview(made, positioned: .below, relativeTo: nil)
        container = made
        return made
    }

    /// The page's current main-frame view (re-read each time: it changes with the renderer).
    var contentView: NSView? {
        guard page != nil, let browser else { return nil }
        return calls?.contentView(browser)
    }

    /// `cmux_browser_in_tree_widget_drawing`; nil while not in tree.
    var widgetDrawing: Int32? {
        guard page != nil, let browser else { return nil }
        return calls?.widgetDrawing(browser)
    }

    /// The window's size when this page last resized (``pageViewResized()``): a resize with the window at another size
    /// is a resize of the window itself.
    private var windowSizeAtLastResize: CGSize?

    /// The host view took a new size in this turn: the page's compositor resized in that layout, and the page joins the
    /// window's resize fence for this turn with the wait ``fenceTimeoutMs(windowResized:fullScreenTransition:refreshMs:)``
    /// gives, so the render server shows the window's commit with the page's first frame at the new size. The main thread
    /// waits for nothing; a miss shows the last frame, pinned top-left and clipped by the container.
    ///
    /// Chrome's rule (`NativeWidgetNSWindowBridge::ShouldWaitInPreCommit`): its window's commit waits for a compositor
    /// frame only while the window's content size differs from its last frame's, and never in a full screen transition
    /// ("no need for updates during such transition", crbug.com/875707). A resize inside the window (a divider drag, a
    /// pane spring) never waits: Chrome's `DelegatedFrameHost` embeds the new surface with a zero deadline and shows the
    /// last frame until it comes. Before this every resize joined: each divider drag frame held the window's commit for
    /// every page's frame (the user's recording: the window at about 28 of 60 frames a second, defects.md 8), and the
    /// full screen transitions held theirs (defects.md 5, 6).
    func pageViewResized() { // perf-hot: 0.05ms cef-geometry (each in-tree page, each motion frame)
        // The page's drawing layer follows its view exactly in the fork (cef#48 one window, `cmux_in_tree_display`).
        guard page != nil, let browser else { return }
        guard let fence = calls?.resizeFence, let view, let window = view.window,
              let layer = view.layer else { return }
        let windowSize = window.frame.size
        let windowResized = windowSizeAtLastResize.map { $0 != windowSize } ?? false
        windowSizeAtLastResize = windowSize
        let refreshMs = (NSScreen.screens.map(\.minimumRefreshInterval).min() ?? 1.0 / 60) * 1_000
        guard let wait = Self.fenceTimeoutMs(windowResized: windowResized || window.inLiveResize,
                                             fullScreenTransition: Motion.isFullScreenTransitioning(window),
                                             refreshMs: refreshMs) else { return }
        var timeout = CEFLayerHosting.resizeFenceTimeoutOverrideMs > 0 ? CEFLayerHosting.resizeFenceTimeoutOverrideMs : wait
        // The adaptive pace (`CMUX_NEXT_CEF_FENCE_PACE=adaptive`, a bench arm): waits longer while the window's pages
        // keep up, none while they fall behind.
        let pace: CEFFencePace? = CEFFencePace.isOn ? resizeFences.pace : nil
        let paceKey = ObjectIdentifier(window)
        if let pace {
            guard let paced = pace.wait(window: paceKey, base: timeout, refreshMs: refreshMs,
                                        windowResized: windowResized || window.inLiveResize) else { return }
            timeout = paced
        }
        resizeFences.join(window: window, layer: layer, timeoutMs: timeout, refreshMs: refreshMs) { [timeout] port, done in
            guard let pace else { return fence(browser, port, timeout, done) }
            return fence(browser, port, timeout) { presented in
                pace.record(window: paceKey, presented: presented)
                done(presented)
            }
        }
    }

    /// How long a page resize holds the window's commit for the page's frame (``pageViewResized()``), in ms; nil holds
    /// nothing.
    /// - A full screen transition holds nothing: AppKit animates a snapshot, and Chrome's window waits for no frame in
    ///   it either (`ShouldWaitInPreCommit`, crbug.com/875707).
    /// - A resize of the window itself waits up to one display frame (at least 8 ms), as before: the window and the page
    ///   take the new size in one frame.
    /// - A resize inside the window (a divider drag, a pane spring) waits at most half a display frame
    ///   (``CEFResizeSyncDeadline/frameShare``, the layer-hosted pages' cap): a page that draws in time shows with its
    ///   pane, and a slow one shows its last frame, pinned top-left and clipped, instead of making the window miss its
    ///   frame. Measured on the other Mac (c76917cb, 120 fps recorder): no wait, 189 of 504 divider-drag frames a frame
    ///   stale; the full wait, 10 of 503 at the same frame count, but the user's heavy page dropped to about 28 of 60
    ///   frames a second with it (defects.md 8).
    nonisolated static func fenceTimeoutMs(windowResized: Bool, fullScreenTransition: Bool, refreshMs: Double) -> Int32? {
        if fullScreenTransition { return nil }
        if windowResized { return Int32(max(8, refreshMs.rounded(.up))) }
        return Int32(max(1, (refreshMs * CEFResizeSyncDeadline.frameShare).rounded(.down)))
    }

    /// Gives the page the keyboard on cmux's behalf (`CEFTab.grantFocus`): Chromium's focus call and the move of the
    /// window's first responder to the page view, both inside one grant the window's gate lets through.
    /// - Returns: Whether the page view is the window's first responder after it.
    @discardableResult
    func grantFocus(_ focus: () -> Void) -> Bool {
        guard let container, let window = container.window else { return false }
        return InTreePageFocus.shared.granting(container) {
            focus()
            guard let target = contentView ?? page else { return false }
            if window.firstResponder === target { return true }
            return FocusRoute(.person, "cmux grants an in-tree page the keyboard").moveKeyboard(in: window, to: target)
        }
    }
}

extension CEFHostView {
    /// A new page window over this view (a pane's Chromium window, a docked DevTools): in the tree when in-tree pages
    /// are on and the engine has the calls (no layer hosting, detached hosting or resize sync for it), else hosted in
    /// the window's layers as before. A page the fork refuses twice goes back to layer hosting.
    func pageWindowCreated(browser: Int32, shim: CEFShimLibrary?, apiVersion: Int32) {
        let fork = CEFLayerHosting.Fork(shim: shim, apiVersion: apiVersion)
        guard inTree.pageWindowCreated(browser: browser, calls: CEFInTreeCalls(shim: shim, apiVersion: apiVersion)) else {
            return layerHosting.pageWindowCreated(browser: browser, fork: fork)
        }
        layerHosting.pageWindowCreated(browser: browser, fork: nil)
        inTree.fallBack = { [weak self] in
            guard let self else { return }
            self.layerHosting.pageWindowCreated(browser: self.inTree.browser ?? browser, fork: fork)
        }
    }
}
