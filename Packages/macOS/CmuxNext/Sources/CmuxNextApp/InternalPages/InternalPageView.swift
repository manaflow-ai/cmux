import AppKit
import CmuxNextCompat
import CmuxNextControl
import CmuxNextDesign
import CmuxNextPages
import class CmuxSafeConcurrency.OnceContinuation
import enum CmuxSafeConcurrency.OnceContinuationError
import func CmuxSafeConcurrency.withOnceContinuation

/// A native page's content whose keyboard goes to a view inside it (a Mac
/// Screen tab's input surface), not to the content view itself.
@MainActor
protocol InternalPageFocusing: NSView {
    var focusTarget: NSView { get }
}

/// A page tab's content: the provider's view filling the pane, under the
/// provider's optional native bar (``InternalPageProvider/makeTopBar(for:)``,
/// the Markdown omnibar), or above it with `browser.toolbarPosition` bottom. `content` is always the provider's view, so code
/// that looks for the page (`content as? PageWebView`) finds it with or without
/// a bar. The pane focuses `focusTarget` when the tab gets the keyboard; a
/// click inside the page moves the responder within it as usual.
///
/// The tab's view can exist before its content (``init(key:page:make:)``): the provider makes the
/// content when the tab first shows (``build()``, or the first read of ``content``), so a tab opened
/// or restored out of sight costs no page. Chrome loads a background tab only once it is activated
/// (chrome/browser/sessions/tab_loader.cc, `NavigationController::LoadIfNecessary`).
final class InternalPageView: NSView {
    /// The provider's view, its optional bar, and what runs once both are in the tab's view.
    struct Parts {
        var content: NSView
        var topBar: NSView?
        /// Runs right after the parts are installed (a discarded tab's picture and state going back).
        var installed: (@MainActor (InternalPageView) -> Void)?
        /// The title a page's stand-in shows from this build until the page's first frame
        /// (``PageWebView/showStandIn(title:)``, feature `pageStandIn`); nil shows none.
        var standInTitle: String?

        init(content: NSView, topBar: NSView? = nil, standInTitle: String? = nil,
             installed: (@MainActor (InternalPageView) -> Void)? = nil) {
            self.content = content
            self.topBar = topBar
            self.standInTitle = standInTitle
            self.installed = installed
        }
    }

    /// The content waiting for the tab's first show, or made.
    private enum Stage {
        case waiting(@MainActor () -> Parts)
        case built(Parts)
    }

    let key: String
    let page: InternalPageID
    private var stage: Stage
    /// Whether the provider's content exists (the tab showed, or a caller read ``content``).
    var isBuilt: Bool {
        if case .built = stage { return true }
        return false
    }
    /// The provider's view, made now when the tab has not shown yet.
    var content: NSView { build().content }

    /// Told this view's page when it is freed with content still in it (``detachContent()`` never ran): its owner let
    /// it go without the teardown the store does (a report only). Runs in the deinit, on the thread that frees the
    /// view, so it may touch only thread-safe sinks (a log, a crash key). Set once, before the view is used.
    func reportFreedAttached(_ report: @escaping @Sendable (InternalPageID) -> Void) {
        freedAttached.withLock { $0 = report }
    }
    private let freedAttached = Mutex<(@Sendable (InternalPageID) -> Void)?>(nil)
    /// Content is in this view (``install(_:)``) and ``detachContent()`` has not run: the deinit reads it.
    private let holdsContent = Atomic<Bool>(false)

    /// Takes every subview out (the content, its bar, a picture) while this view lives; the store calls it when the
    /// tab's view goes (close, discard). A page must never leave its hierarchy inside this view's `-[NSView dealloc]`:
    /// a hidden tab's page then loses its hidden ancestor there, and the CEF fork's parent tracker stores a weak
    /// reference to the deallocating view and aborts the app (cmux21 cmux-2026-10-28-114922.ips, a closed Settings tab).
    func detachContent() {
        holdsContent.store(false, ordering: .relaxed)
        for subview in subviews { subview.removeFromSuperview() }
    }

    // cx-t7hu pattern: not an isolated deinit (a runtime hop traps when released inside an action's task-local scope).
    // It reads only Sendable state (an atomic, a lock, a let).
    nonisolated deinit {
        guard holdsContent.load(ordering: .relaxed), let report = freedAttached.withLock({ $0 }) else { return }
        report(page)
    }
    /// The native bar above the content (below it, ``toolbarPosition``); it sets its own height.
    /// Nil until the content is made.
    var topBar: NSView? {
        if case .built(let parts) = stage { return parts.topBar }
        return nil
    }
    /// The edge `topBar` sits on (`browser.toolbarPosition`); the pane sets it.
    var toolbarPosition: ToolbarPosition = .top {
        didSet {
            guard toolbarPosition != oldValue else { return }
            barEdge.activate(toolbarPosition)
            needsLayout = true // invalidate: the bar moved to the other edge (the guard above).
        }
    }
    /// The constraints that put `topBar` above or below the content; one set is active.
    private let barEdge = ToolbarEdgeConstraints()

    /// A tab view whose content is made already.
    convenience init(key: String, page: InternalPageID, content: NSView, topBar: NSView? = nil, standInTitle: String? = nil) {
        self.init(key: key, page: page) { Parts(content: content, topBar: topBar, standInTitle: standInTitle) }
        build()
    }

    /// A tab view whose content `make` makes at its first ``build()``.
    init(key: String, page: InternalPageID, make: @escaping @MainActor () -> Parts) {
        self.key = key
        self.page = page
        self.stage = .waiting(make)
        super.init(frame: .zero)
        setAccessibilityIdentifier("cmux.page.\(page.rawValue)")
    }

    /// Makes and installs the content the first time; later calls return it.
    @discardableResult
    func build() -> Parts {
        switch stage {
        case .built(let parts):
            return parts
        case .waiting(let make):
            let parts = make()
            stage = .built(parts)
            install(parts)
            parts.installed?(self)
            // A cold page shows its stand-in from this turn; a discarded tab's picture covers it instead.
            if let title = parts.standInTitle, picture == nil, let page = parts.content as? PageWebView {
                page.showStandIn(title: title)
            }
            return parts
        }
    }

    private func install(_ parts: Parts) {
        holdsContent.store(true, ordering: .relaxed)
        let content = parts.content
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        if let topBar = parts.topBar {
            topBar.translatesAutoresizingMaskIntoConstraints = false
            addSubview(topBar)
            NSLayoutConstraint.activate([
                topBar.leadingAnchor.constraint(equalTo: leadingAnchor),
                topBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            ])
            barEdge.top = [
                topBar.topAnchor.constraint(equalTo: topAnchor),
                content.topAnchor.constraint(equalTo: topBar.bottomAnchor),
                content.bottomAnchor.constraint(equalTo: bottomAnchor),
            ]
            barEdge.bottom = [
                content.topAnchor.constraint(equalTo: topAnchor),
                content.bottomAnchor.constraint(equalTo: topBar.topAnchor),
                topBar.bottomAnchor.constraint(equalTo: bottomAnchor),
            ]
            barEdge.activate(toolbarPosition)
        } else {
            NSLayoutConstraint.activate([
                content.topAnchor.constraint(equalTo: topAnchor),
                content.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        }
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The view that takes the keyboard when the tab is focused: a native
    /// page's primary input (the docked Home's message box), a React page's
    /// web content itself, so typing reaches the page without a click first,
    /// a gated page's SwiftUI (``VisibilityGatedHostingView/focusTarget``),
    /// or the view a native page names (``InternalPageFocusing``).
    var focusTarget: NSView {
        if let input = (content as? any PrimaryInputTarget)?.primaryInputView { return input }
        if let page = content as? PageWebView { return page.focusView }
        if let gate = content as? VisibilityGatedHostingView { return gate.focusTarget }
        return (content as? any InternalPageFocusing)?.focusTarget ?? content
    }

    override var acceptsFirstResponder: Bool { false }

    // MARK: Rebuilt after a discard

    /// The page's last picture over its rebuilt content until the document painted its restored
    /// state, so a discarded tab shows in its first frame (Chrome shows a discarded tab's last
    /// frame while it reloads, `TabLoader`). Nil once it did, or for native content (it draws at once).
    private(set) var picture: NSView?
    /// Runs once the view has a size (a restored scroll position needs the document laid out).
    private var afterLayout: (() -> Void)?
    /// The rebuilt content's state going back (``rebuilt(under:restore:)``), until the page drew it.
    private(set) var restoring: Task<Void, Never>?

    /// This view replaces one a discard let go: `image` covers a page until it paints, then
    /// `restore` puts its state back once it can take it (a page once its new document painted,
    /// native content once it has a size), and the cover goes once the page drew that state.
    func rebuilt(under image: CGImage?, restore: @escaping @MainActor (NSView) async -> Void) {
        guard let page = content as? PageWebView else {
            return whenLaidOut { [weak self] in self?.startRestoring(restore) }
        }
        if let image, !page.hasPainted { cover(with: image) }
        page.whenPainted { [weak self, weak page] in
            guard let page else { return }
            self?.startRestoring { content in
                await restore(content)
                // The restored state reached the screen: the page's next frame, then the cover goes.
                _ = try? await withOnceContinuation { (done: OnceContinuation<Void, OnceContinuationError>) in page.afterNextFrame { done.resume(returning: ()) } }
            }
        }
    }

    private func startRestoring(_ body: @escaping @MainActor (NSView) async -> Void) {
        let content = content
        // task-owner: restoring; one state put back on this view, then its cover goes
        // main-hop-allow: `body` is a main-actor async restore of this view; each of its awaits resumes on main either way
        restoring = Task { @MainActor [weak self] in
            await body(content)
            self?.removeCover()
        }
    }

    private func cover(with image: CGImage) {
        guard picture == nil else { return }
        let cover = NSView()
        cover.wantsLayer = true
        cover.layer?.contents = image
        cover.layer?.contentsGravity = .resizeAspectFill
        cover.translatesAutoresizingMaskIntoConstraints = false
        addSubview(cover, positioned: .above, relativeTo: content)
        NSLayoutConstraint.activate([
            cover.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            cover.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            cover.topAnchor.constraint(equalTo: content.topAnchor),
            cover.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        picture = cover
    }

    private func removeCover() {
        picture?.removeFromSuperview()
        picture = nil
    }

    /// A picture of the page as it draws now, taken when the tab hides (a hidden page cannot be
    /// pictured); nil for native content (it draws again at once), a page that has not painted, or
    /// an engine that does not answer within 2 s. A page the page lifecycle pictured at this hide shares
    /// that capture (one engine capture per hide); the engine is asked only when it brought no frame.
    func lastPicture() async -> CGImage? {
        guard let page = content as? PageWebView, page.hasPainted else { return nil }
        return try? await ControlDeadline.shared.run(method: "pages.discard.picture", deadline: .now + .seconds(2)) { @MainActor in
            if let frame = await page.hideFrame() { return frame }
            return await page.snapshot()?.bestCGImage
        }
    }

    /// Runs `body` at the next layout with a size: now when the view has one.
    private func whenLaidOut(_ body: @escaping () -> Void) {
        guard bounds.isEmpty else { return body() }
        afterLayout = body
        needsLayout = true // invalidate: `body` waits for the first layout with a size.
    }

    override func layout() {
        super.layout()
        guard !bounds.isEmpty, let body = afterLayout else { return }
        afterLayout = nil
        body()
    }

    /// Runs Go Back (true) or Go Forward (false): the mouse side buttons and a
    /// swipe over the page (history.md 4.2b). Set by the page's host.
    var navigate: ((Bool) -> Void)?

    /// Buttons 4 and 5 (AppKit numbers 3 and 4): Back and Forward, as in a browser.
    override func otherMouseUp(with event: NSEvent) {
        guard let navigate, event.buttonNumber == 3 || event.buttonNumber == 4 else { return super.otherMouseUp(with: event) }
        navigate(event.buttonNumber == 3)
    }

    /// A swipe to the right is Back, to the left Forward (WebKit's rule).
    override func swipe(with event: NSEvent) {
        guard let navigate, event.deltaX != 0 else { return super.swipe(with: event) }
        navigate(event.deltaX > 0)
    }
}

extension InternalPageView: ToolbarEdgeHosting {}

/// A show's returned tab view, for the request its first show reads (``PageOpenRequests``).
extension InternalPageView: PageOpenTarget {}
