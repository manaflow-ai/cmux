import AppKit
import CmuxNextControl
import CmuxNextDesign
import CmuxNextPages

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
final class InternalPageView: NSView {
    let key: String
    let page: InternalPageID
    let content: NSView
    /// The native bar above the content (below it, ``toolbarPosition``); it sets its own height.
    let topBar: NSView?
    /// The edge `topBar` sits on (`browser.toolbarPosition`); the pane sets it.
    var toolbarPosition: ToolbarPosition = .top {
        didSet {
            guard toolbarPosition != oldValue else { return }
            barEdge.activate(toolbarPosition)
            needsLayout = true
        }
    }
    /// The constraints that put `topBar` above or below the content; one set is active.
    private let barEdge = ToolbarEdgeConstraints()

    init(key: String, page: InternalPageID, content: NSView, topBar: NSView? = nil) {
        self.key = key
        self.page = page
        self.content = content
        self.topBar = topBar
        super.init(frame: .zero)
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        if let topBar {
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
        setAccessibilityIdentifier("cmux.page.\(page.rawValue)")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The view that takes the keyboard when the tab is focused: a native
    /// page's primary input (the docked Home's message box), a React page's
    /// web content itself, so typing reaches the page without a click first,
    /// or the view a native page names (``InternalPageFocusing``).
    var focusTarget: NSView {
        if let input = (content as? any PrimaryInputTarget)?.primaryInputView { return input }
        if let page = content as? PageWebView { return page.focusView }
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
                await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in page.afterNextFrame { done.resume() } }
            }
        }
    }

    private func startRestoring(_ body: @escaping @MainActor (NSView) async -> Void) {
        let content = content
        // task-owner: restoring; one state put back on this view, then its cover goes
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
            return await page.snapshot()?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        }
    }

    /// Runs `body` at the next layout with a size: now when the view has one.
    private func whenLaidOut(_ body: @escaping () -> Void) {
        guard bounds.isEmpty else { return body() }
        afterLayout = body
        needsLayout = true
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
