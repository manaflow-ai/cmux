public import AppKit

/// Places dialogs (`CmuxDialogCenter` calls it).
@MainActor
public protocol CmuxDialogHosting: AnyObject {
    /// Shows `dialog`; `scopeGone` runs if the scope disappears first (the
    /// tab or window closed), and the center then cancels the dialog.
    func show(_ dialog: CmuxDialogPresentation, in scope: CmuxDialogScope, scopeGone: @escaping () -> Void)
    func hide(_ dialog: CmuxDialogPresentation)
}

/// What draws dialogs for ``CmuxDialogOverlayHost``: ``CmuxDialogNativeDrawing`` (AppKit) by default; tests
/// pass their own. A view it returns fills the dialog's region (the window, or the tab) and draws the card in it.
@MainActor
public protocol CmuxDialogDrawing: AnyObject {
    /// The view that draws `dialog` in `window` (nil: the app host); nil when none can.
    func attach(_ dialog: CmuxDialogPresentation, in window: NSWindow?) -> NSView?
    /// Gives the keyboard to what draws `dialog` (the page inside its view), once it is on screen.
    func focus(_ dialog: CmuxDialogPresentation)
    /// `dialog` ended: its view may draw the next one.
    func detach(_ dialog: CmuxDialogPresentation)
    /// Runs `ready` once `dialog`'s view, presented at its transparent first frame, has drawn its card,
    /// so the host fades in a drawn card, never an empty or late one; at once by default.
    func whenDrawn(_ dialog: CmuxDialogPresentation, _ ready: @escaping () -> Void)
}

public extension CmuxDialogDrawing {
    func whenDrawn(_ dialog: CmuxDialogPresentation, _ ready: @escaping () -> Void) { ready() }
}

/// Dialogs on the R84 overlay host: a window-scope dialog is a dimming
/// modal overlay over the whole window; a tab-scope dialog is a modal
/// overlay centered on the tab with the tab's rect as its `modalRegion`,
/// shown only while the tab shows (a tab switch hides it, it does not end
/// it); an app-scope dialog (no window) uses `WindowOverlayHost.appHost()`.
/// A closed window ends its dialogs (the cancel answer). The
/// dialog handles Escape itself (its cancel button, `CmuxDialogKeys`), so
/// the overlay does not dismiss on Escape.
@MainActor
public final class CmuxDialogOverlayHost: CmuxDialogHosting {
    private final class Shown {
        let dialog: CmuxDialogPresentation
        /// Weak: the overlay never keeps a closed tab alive.
        let scope: CmuxDialogWeakScope
        let scopeGone: () -> Void
        var handle: OverlayHandle?
        /// The drawing drew the card (``CmuxDialogDrawing/whenDrawn(_:_:)``): a show after it fades in at once.
        var drawn = false
        var watcher: CmuxDialogScopeWatcher?

        init(dialog: CmuxDialogPresentation, scope: CmuxDialogScope, scopeGone: @escaping () -> Void) {
            self.dialog = dialog
            self.scope = CmuxDialogWeakScope(scope)
            self.scopeGone = scopeGone
        }
    }

    /// What draws the dialogs (``CmuxDialogNativeDrawing`` unless a test passes its own); nil draws none, and
    /// its dialogs wait for the center's next host (``CmuxDialogCenter/host``).
    private let drawing: (any CmuxDialogDrawing)?
    /// The least size of an app-scope dialog's region (no window to fill); it grows to hold the card.
    static let appRegion = NSSize(width: 520, height: 420)
    /// Room around an app-scope card for its shadow.
    static let appMargin: CGFloat = 64

    /// Room around a tab dialog's card that does not fit its tab.
    static let tabMargin: CGFloat = 16

    /// A tab dialog's region (window coordinates): the tab, grown about its center to hold `card` and
    /// kept inside `window` (the window's content) where it fits there.
    static func tabRegion(_ tab: NSRect, holding card: CGRect?, in window: NSRect?) -> NSRect {
        guard let card else { return tab }
        let width = max(tab.width, ceil(card.width) + tabMargin * 2)
        let height = max(tab.height, ceil(card.height) + tabMargin * 2)
        var region = NSRect(x: tab.midX - width / 2, y: tab.midY - height / 2, width: width, height: height)
        if let window {
            region.origin.x = min(max(region.minX, window.minX), max(window.minX, window.maxX - width))
            region.origin.y = min(max(region.minY, window.minY), max(window.minY, window.maxY - height))
        }
        return region
    }

    /// A tab dialog's region, its tab (the blocked region) and its card (the dialog view's coordinates;
    /// empty before the card laid out): the region takes clicks only on the card, so a neighboring pane
    /// the region grew over keeps its clicks outside the card.
    private static func tabPlacement(_ entry: Shown) -> (region: NSRect, tab: NSRect, card: NSRect)? {
        guard case .tab(let view)? = entry.scope.live, let window = view.window else { return nil }
        let tab = view.convert(view.bounds, to: nil)
        let content = window.contentView.map { $0.convert($0.bounds, to: nil) }
        return (tabRegion(tab, holding: entry.dialog.cardRect, in: content), tab, entry.dialog.cardRect ?? .zero)
    }

    /// The app-scope region for a card of `card` points: never smaller than ``appRegion``, so a card the
    /// interface scale makes wider or a long dialog makes taller is never clipped by the panel.
    static func appRegion(holding card: CGRect?) -> NSSize {
        guard let card else { return appRegion }
        return NSSize(width: max(appRegion.width, ceil(card.width) + appMargin * 2),
                      height: max(appRegion.height, ceil(card.height) + appMargin * 2))
    }

    private var shown: [ObjectIdentifier: Shown] = [:]
    /// Brings the app forward for an app-scope dialog: the app host hides
    /// while cmux is inactive, so a dialog with no window (quit from the
    /// Dock) would not be seen. Never in a no-activate launch.
    private let activate: () -> Void
    private let isAppActive: () -> Bool

    public init(drawing: (any CmuxDialogDrawing)? = CmuxDialogNativeDrawing(), activate: @escaping () -> Void = { if !WindowPlacement.noActivate { NSApp.activate() } },
                isAppActive: @escaping () -> Bool = { NSApp.isActive }) {
        self.drawing = drawing
        self.activate = activate
        self.isAppActive = isAppActive
    }

    /// The overlay options for `scope`.
    public static func options(for scope: CmuxDialogScope) -> OverlayOptions {
        switch scope {
        case .tab(let view):
            let rect = view.window == nil ? view.bounds : view.convert(view.bounds, to: nil)
            return OverlayOptions(kind: .dialog, anchor: rect, isModal: true, dismissOnEscape: false, dimsContent: false,
                                  passesThroughClicks: false, modalRegion: rect)
        case .window, .app:
            return OverlayOptions(kind: .dialog, anchor: windowRegion(scope), isModal: true, dismissOnEscape: false, dimsContent: true,
                                  passesThroughClicks: false)
        }
    }

    /// A window-scope dialog's region: the window's content (window coordinates); nil for the app host.
    private static func windowRegion(_ scope: CmuxDialogScope) -> NSRect? {
        guard case .window(let window) = scope, let content = window.contentView else { return nil }
        return content.convert(content.bounds, to: nil)
    }

    public func show(_ dialog: CmuxDialogPresentation, in scope: CmuxDialogScope, scopeGone: @escaping () -> Void) {
        let entry = Shown(dialog: dialog, scope: scope, scopeGone: scopeGone)
        shown[ObjectIdentifier(dialog)] = entry
        if case .tab(let view) = scope {
            // A tab's dialog follows its tab: hidden while the tab is not in
            // a window or is hidden (a tab switch), back when it shows again.
            let watcher = CmuxDialogScopeWatcher(watching: view)
            watcher.onVisibilityChange = { [weak self, weak entry] in
                guard let self, let entry else { return }
                self.sync(entry)
            }
            watcher.onResize = { [weak entry] in
                guard let entry, let place = Self.tabPlacement(entry) else { return }
                entry.dialog.view?.setFrameSize(place.region.size)
                entry.handle?.update(anchor: place.region, modalRegion: place.tab, mouseRect: place.card)
            }
            entry.watcher = watcher
        }
        sync(entry)
    }

    public func hide(_ dialog: CmuxDialogPresentation) {
        guard let entry = shown.removeValue(forKey: ObjectIdentifier(dialog)) else { return }
        entry.watcher?.stop()
        detach(entry)
        drawing?.detach(dialog)
    }

    /// Presents or withdraws the overlay to match the scope's visibility.
    private func sync(_ entry: Shown) {
        guard let scope = entry.scope.live else { return detach(entry) }
        let host: WindowOverlayHost?
        switch scope {
        case .tab(let view): host = entry.watcher?.isShowing == true ? view.window.map(WindowOverlayHost.host(for:)) : nil
        case .window(let window): host = WindowOverlayHost.host(for: window)
        case .app:
            host = WindowOverlayHost.appHost()
            if entry.handle == nil, !isAppActive() { activate() }
        }
        guard let host else { return detach(entry) }
        if let handle = entry.handle, !handle.isDismissed, handle.host === host { return }
        detach(entry)
        // A tab's dialog shown again after a tab switch keeps its view: only its end gives the view back.
        guard let view = entry.dialog.view ?? drawing?.attach(entry.dialog, in: scope.window) else { return }
        var options = Self.options(for: scope)
        if let place = Self.tabPlacement(entry) {
            options.anchor = place.region
            options.modalRegion = place.tab
            options.mouseRect = place.card
        }
        view.frame = NSRect(origin: .zero, size: options.anchor?.size ?? Self.appRegion(holding: entry.dialog.cardRect))
        entry.dialog.view = view
        // The first show waits at its transparent first frame in the panel until the drawing says the card
        // drew (the native card at once), and fades in then.
        var presented = options
        presented.holdsEntrance = drawing != nil && !entry.drawn
        let handle = host.present(view, options: presented)
        if presented.holdsEntrance {
            drawing?.whenDrawn(entry.dialog) { [weak handle, weak entry] in
                entry?.drawn = true
                handle?.beginEntrance()
            }
        }
        // The window closed (its host dismissed every overlay): the dialog ends.
        handle.onDismiss = entry.scopeGone
        if case .app = scope {
            // The panel holds the card as it lays out: the region grows to it, and the panel follows.
            entry.dialog.onCardRect = { [weak handle, weak view, weak dialog = entry.dialog] in
                guard let handle, let view, let dialog else { return }
                let size = Self.appRegion(holding: dialog.cardRect)
                guard view.frame.size != size else { return }
                view.setFrameSize(size)
                handle.host?.layout(handle)
            }
            // A card laid out before the panel showed.
            entry.dialog.onCardRect?()
        }
        if case .tab = scope {
            // A card wider or taller than its tab (a narrow split) keeps its whole card: the region grows
            // around the tab, inside the window, while only the tab and the card take clicks.
            entry.dialog.onCardRect = { [weak handle, weak view, weak entry] in
                guard let handle, let view, let entry, let place = Self.tabPlacement(entry) else { return }
                if view.frame.size != place.region.size { view.setFrameSize(place.region.size) }
                handle.update(anchor: place.region, modalRegion: place.tab, mouseRect: place.card)
            }
            entry.dialog.onCardRect?()
        }
        if case .window = scope {
            // The region fills the window: it follows the window's size.
            handle.onWindowGeometryChange = { [weak handle, weak view] in
                guard let handle, let view, let region = Self.windowRegion(scope) else { return }
                view.setFrameSize(region.size)
                handle.update(anchor: region)
            }
        }
        entry.handle = handle
        entry.dialog.notePresented(true)
        drawing?.focus(entry.dialog)
    }

    private func detach(_ entry: Shown) {
        entry.dialog.notePresented(false)
        guard let handle = entry.handle else { return }
        entry.handle = nil
        handle.onDismiss = nil
        handle.dismiss()
    }
}

/// An invisible view filling a tab's view: tells the dialog host when the
/// tab shows or stops showing (it leaves its window or is hidden) and when
/// it changes size.
@MainActor
final class CmuxDialogScopeWatcher: NSView {
    var onVisibilityChange: (() -> Void)?
    var onResize: (() -> Void)?

    init(watching view: NSView) {
        super.init(frame: view.bounds)
        autoresizingMask = [.width, .height]
        alphaValue = 0
        setAccessibilityElement(false)
        view.addSubview(self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// In a window and not hidden (itself or an ancestor).
    var isShowing: Bool { window != nil && !isHiddenOrHasHiddenAncestor }

    /// The tab's rect in window coordinates.
    var windowRect: NSRect? { superview.map { $0.convert($0.bounds, to: nil) } }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        onResize?()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onVisibilityChange?()
    }

    override func viewDidHide() {
        super.viewDidHide()
        onVisibilityChange?()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        onVisibilityChange?()
    }

    func stop() {
        onVisibilityChange = nil
        onResize = nil
        removeFromSuperview()
    }
}
