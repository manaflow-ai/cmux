public import AppKit
import CmuxNextDesign

// Extensions toolbar and menu, the width-driven toolbar collapse, and
// history recording.
extension BrowserChromeView {
    /// Accessibility identifiers of the toolbar (UI automation, e2e suites).
    public enum Identifier {
        public static let back = "browser.toolbar.back"
        public static let forward = "browser.toolbar.forward"
        public static let reload = "browser.toolbar.reload"
        public static let omnibar = "browser.toolbar.omnibar"
        public static let extensionsButton = "browser.extensions.button"
        public static let pageGone = "browser.page.gone"
        public static let pageGoneReload = "browser.page.gone.reload"
        public static let pageUnresponsive = "browser.page.unresponsive"
        public static let pageUnresponsiveWait = "browser.page.unresponsive.wait"
        public static let pageUnresponsiveExit = "browser.page.unresponsive.exit"
        public static func extensionAction(_ id: String) -> String { "browser.extension.action.\(id)" }
    }

    /// Runs the Extensions menu's items (the App's action registry). Nil
    /// drives the extension store directly.
    public var extensionMenuHandler: (any ExtensionMenuHandling)? {
        get { extensionToolbar.menuHandler }
        set { extensionToolbar.menuHandler = newValue }
    }

    /// Shows the Extensions (puzzle) menu of a Chromium tab. Runs the menu's
    /// tracking loop: call it from an event or a main-actor task.
    public func showExtensionsMenu() { extensionToolbar.showMenu() }

    /// Shows one extension's menu at its toolbar button (or the Extensions
    /// button when it is not shown).
    public func showExtensionItemMenu(_ id: String) { extensionToolbar.showItemMenu(id) }

    /// Opens the Extensions menu (or `id`'s menu) on the next run-loop turn,
    /// for callers that must return first (CLI, palette, debug socket). The
    /// menu's tracking loop then runs in a run-loop callout, not inside a
    /// main-queue job, so main-actor work (control calls) keeps running
    /// while it is open.
    public func presentExtensionsMenu(for id: String? = nil) {
        CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let id { self.showExtensionItemMenu(id) } else { self.showExtensionsMenu() }
            }
        }
        CFRunLoopWakeUp(CFRunLoopGetMain())
    }

    /// Runs an extension's toolbar action anchored to its button (or the
    /// Extensions button when it is not pinned or has no room).
    public func runExtensionAction(_ id: String) { extensionToolbar.run(id) }

    /// The Extensions menu or an extension's menu while it is open.
    public var presentedExtensionsMenu: NSMenu? { extensionToolbar.presentedMenu }

    /// What the toolbar shows now (`debug.extensions.toolbar`).
    public var toolbarReport: BrowserToolbarReport {
        var frames: [String: CGRect] = [:]
        func add(_ key: String, _ view: NSView?) {
            guard let view, !view.isHidden, view.superview != nil, view.window != nil else { return }
            // Constraints place the alignment rect (NSButton frames carry
            // extra insets for the bezel).
            let alignment = view.alignmentRect(forFrame: view.frame)
            frames[key] = view.superview.map { $0.convert(alignment, to: self) } ?? alignment
        }
        add("back", backButton)
        add("forward", forwardButton)
        add("reload", reloadButton)
        add("omnibar", addressBar)
        if extensionToolbar.isShowingExtensions { add("extensions", extensionToolbar.puzzle) }
        for id in extensionToolbar.visibleIDs { add("action:\(id)", extensionToolbar.button(for: id)) }
        let host = extensionToolbar.host
        return BrowserToolbarReport(
            width: bounds.width, showsForward: !forwardButton.isHidden,
            showsExtensionsButton: extensionToolbar.isShowingExtensions,
            visibleActions: extensionToolbar.visibleIDs, overflowActions: extensionToolbar.overflowIDs,
            openPopup: host?.openExtensionPopup,
            popupAnchor: host?.openExtensionPopup.flatMap { extensionToolbar.anchorRect(for: $0) }
                .map { tab.contentView.convert($0, to: self) },
            frames: frames, toolbarBounds: toolbar.convert(toolbar.bounds, to: self)
        )
    }

    public override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = newSize.width != frame.width
        super.setFrameSize(newSize)
        guard widthChanged else { return }
        // A popup hangs off a toolbar button that moves or collapses now.
        extensionToolbar.hidePopups()
        applyToolbarLayout()
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { extensionToolbar.hidePopups() }
    }

    /// The region of this chrome that contains `view`, nil when outside.
    public func region(of view: NSView) -> Region? {
        guard view.isDescendant(of: self) else { return nil }
        if view.isDescendant(of: addressBar) { return .addressBar }
        if view.isDescendant(of: findBar) { return .findBar }
        if view.isDescendant(of: tab.contentView) { return .page }
        return .chrome
    }

    /// Collapses the toolbar for the pane's width (BrowserToolbarLayout).
    func applyToolbarLayout() {
        let resolved = BrowserToolbarLayout.resolve(
            width: bounds.width, pinned: extensionToolbar.pinnedCount,
            showsExtensions: extensionToolbar.isShowingExtensions, metrics: Self.toolbarMetrics
        )
        guard resolved != toolbarLayout else { return }
        toolbarLayout = resolved
        forwardButton.isHidden = !resolved.showsForward
        extensionToolbar.visibleLimit = resolved.visiblePinned
    }

    static var toolbarMetrics: BrowserToolbarLayout.Metrics {
        BrowserToolbarLayout.Metrics(
            button: OmnibarStyle.buttonSize, navigationSpacing: OmnibarStyle.buttonSpacing,
            extensionSpacing: BrowserMetrics.buttonSpacing, inset: OmnibarStyle.toolbarInset,
            margin: OmnibarStyle.barMargin, preferredAddress: Metrics.tabMaxWidth,
            minimumAddress: BrowserMetrics.minimumAddressWidth
        )
    }

    /// Records finished loads for omnibar suggestions.
    func recordHistory(_ state: BrowserTabState) {
        guard let history, case .finished = state.phase, let url = state.url else { return }
        if url != recordedURL {
            recordedURL = url
            recordedTitle = state.title
            history.recordVisit(url: url, title: state.title, at: Date())
        } else if let title = state.title, title != recordedTitle {
            recordedTitle = title
            history.updateTitle(title, for: url)
        }
    }
}

/// The browser toolbar as laid out now, in chrome view coordinates.
public struct BrowserToolbarReport: Equatable, Sendable {
    public var width: CGFloat
    public var showsForward: Bool
    public var showsExtensionsButton: Bool
    /// Pinned actions shown as buttons, in order.
    public var visibleActions: [String]
    /// Pinned actions in the Extensions menu for lack of room.
    public var overflowActions: [String]
    public var openPopup: String?
    /// Where the open popup is anchored (its button, or the Extensions button).
    public var popupAnchor: CGRect?
    /// Visible controls: "back", "forward", "reload", "omnibar",
    /// "extensions", "action:<id>".
    public var frames: [String: CGRect]
    public var toolbarBounds: CGRect

    /// Every control lies inside the toolbar and no two overlap.
    public var fits: Bool {
        let rects = Array(frames.values)
        for (index, rect) in rects.enumerated() {
            guard rect.width > 0, toolbarBounds.insetBy(dx: -0.5, dy: -0.5).contains(rect) else { return false }
            for other in rects[(index + 1)...] where rect.insetBy(dx: 0.5, dy: 0.5).intersects(other) { return false }
        }
        return true
    }
}
