public import AppKit

/// One Mac Screen page tab (`MacScreenPages`): the home page, or one paired
/// Mac's screen (`MacScreenPane`), in a view of its own. No browser engine,
/// no address bar. Connect on the home page and Home on a screen swap what
/// the tab shows in place.
@MainActor
public final class MacScreenTab {
    public let key: String
    public internal(set) var record: MacScreenRecord
    public let view = MacScreenTabView()
    /// The screen; nil for the home page.
    public private(set) var pane: MacScreenPane?
    /// What the tab shows until its screen is in (the home page, or nothing).
    private var home: NSView?
    /// Reading the store for the home page (tests wait on it).
    var loading: Task<Void, Never>?

    init(key: String, record: MacScreenRecord) {
        self.key = key
        self.record = record
        view.onVisibilityChange = { [weak self] shown in
            guard let pane = self?.pane else { return }
            if shown { pane.resume() } else { pane.pause() }
        }
    }

    /// The tab's title: the Mac's name, or "Screen Sharing".
    var title: String { pane?.model.name ?? L.t("macScreen.tab.homeTitle", "Screen Sharing") }

    /// Shows the home page `home`, ending any screen.
    func showHome(_ home: NSView) {
        clear()
        self.home = home
        view.fill(with: home, focus: home)
    }

    /// Shows `pane` (a record whose Mac is read), ending what showed before.
    func install(_ pane: MacScreenPane) {
        clear()
        self.pane = pane
        view.fill(with: pane.view, focus: pane.focusTarget)
        if view.isShown { pane.resume() }
    }

    /// Nothing yet.
    func showLoading() {
        clear()
        view.fill(with: nil, focus: nil)
    }

    func rename(_ name: String) { pane?.model.name = name }

    /// The tab closed or shows something else: its session ends now.
    func clear() {
        loading?.cancel()
        loading = nil
        pane?.close()
        pane = nil
        home = nil
    }
}

/// A Mac Screen tab's content. It reports when it is shown (in a window and
/// not hidden: a pane removes the content of a tab it stops showing, and a
/// hidden workspace hides it) and gives the keyboard to the screen's input
/// surface (`focusTarget`).
public final class MacScreenTabView: NSView {
    /// The tab is shown (true) or stops showing (false).
    public var onVisibilityChange: ((Bool) -> Void)?
    public private(set) var isShown = false
    private weak var content: NSView?
    private weak var keyTarget: NSView?

    public init() {
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The view that takes the keyboard when the tab is focused.
    public var focusTarget: NSView { keyTarget ?? self }

    public override var acceptsFirstResponder: Bool { true }

    func fill(with view: NSView?, focus: NSView?) {
        let hadKeyboard = window.map { window in
            (window.firstResponder as? NSView).map { $0 === self || $0.isDescendant(of: self) } ?? false
        } ?? false
        content?.removeFromSuperview()
        content = view
        keyTarget = focus
        if let view {
            view.frame = bounds
            view.autoresizingMask = [.width, .height]
            addSubview(view)
        }
        // The tab had the keyboard (a focused tab whose screen just came in): its input surface takes it.
        if hadKeyboard { window?.makeFirstResponder(focusTarget) }
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateShown()
    }

    public override func viewDidHide() {
        super.viewDidHide()
        updateShown()
    }

    public override func viewDidUnhide() {
        super.viewDidUnhide()
        updateShown()
    }

    private func updateShown() {
        let shown = window != nil && !isHiddenOrHasHiddenAncestor
        guard shown != isShown else { return }
        isShown = shown
        onVisibilityChange?(shown)
    }
}
