public import AppKit
public import CmuxNextWakeups

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
            guard let self, let pane else { return }
            if shown { pane.resume() } else { pane.pause() }
        }
    }

    /// Whether a person can see the tab (``MacScreenTabView/node``): its home page and its
    /// screen's chrome update only while it is visible, and read once when it shows.
    public var node: VisibilityNode { view.node }

    /// The tab's title: the Mac's name, or "Mac Screen".
    var title: String { pane?.model.name ?? L.t("macScreen.tab.homeTitle", "Mac Screen") }

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
///
/// Shown is its ``node``'s state (plans/cmux-next/chrome-parity/p06-scheduler.md, recipe R-hide):
/// the node sits under a root that is visible while the view is in a window, and its own state is
/// AppKit's hidden state, which `viewDidHide` / `viewDidUnhide` forward (AppKit sends both for a
/// hidden ancestor too), so only a move to a window reads the ancestors. Chromium keeps one visibility per
/// WebContents, set by its owner (`content/public/browser/visibility.h`).
public final class MacScreenTabView: NSView {
    /// The tab is shown (true) or stops showing (false), after the node's flip.
    public var onVisibilityChange: ((Bool) -> Void)?
    /// The tab's node: visible while the view is in a window and not hidden.
    public let node: VisibilityNode
    /// The parent of ``node``: visible while the view is in a window.
    private let windowed: VisibilityNode
    private var flips: VisibilitySubscription?
    private weak var content: NSView?
    private weak var keyTarget: NSView?

    public init() {
        let windowed = VisibilityNode(root: "mac-screen.tab.window", own: .hidden)
        self.windowed = windowed
        node = VisibilityNode("mac-screen.tab", own: .visible, parent: windowed)
        super.init(frame: .zero)
        flips = node.subscribe(owner: "mac-screen.tab") { [weak self] visibility in
            self?.onVisibilityChange?(visibility == .visible)
        }
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// In a window and not hidden.
    public var isShown: Bool { node.isVisible }

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
        if window != nil {
            // visibility-walk-allow: one read per window move, for an ancestor hidden before the move (no viewDidHide then)
            node.set(isHiddenOrHasHiddenAncestor ? .hidden : .visible)
        }
        windowed.set(window == nil ? .hidden : .visible)
    }

    public override func viewDidHide() {
        super.viewDidHide()
        node.set(.hidden)
    }

    public override func viewDidUnhide() {
        super.viewDidUnhide()
        node.set(.visible)
    }
}
