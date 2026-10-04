public import AppKit

/// Places a dialog view in its scope and blocks only that scope. The app
/// uses `CmuxDialogOverlayHost` (the R84 `WindowOverlayHost`, above every
/// Chromium page); tests may pass a recording host.
@MainActor
public protocol CmuxDialogHosting: AnyObject {
    /// Shows `dialog`; `scopeGone` runs if the scope disappears first (the
    /// tab or window closed), and the center then cancels the dialog.
    func show(_ dialog: CmuxDialogView, in scope: CmuxDialogScope, scopeGone: @escaping () -> Void)
    func hide(_ dialog: CmuxDialogView)
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
        let dialog: CmuxDialogView
        /// Weak: the overlay never keeps a closed tab alive.
        let scope: CmuxDialogWeakScope
        let scopeGone: () -> Void
        var handle: OverlayHandle?
        var watcher: CmuxDialogScopeWatcher?

        init(dialog: CmuxDialogView, scope: CmuxDialogScope, scopeGone: @escaping () -> Void) {
            self.dialog = dialog
            self.scope = CmuxDialogWeakScope(scope)
            self.scopeGone = scopeGone
        }
    }

    private var shown: [ObjectIdentifier: Shown] = [:]
    /// Brings the app forward for an app-scope dialog: the app host hides
    /// while cmux is inactive, so a dialog with no window (quit from the
    /// Dock) would not be seen. Never in a no-activate launch.
    private let activate: () -> Void

    public init(activate: @escaping () -> Void = { if !WindowPlacement.noActivate { NSApp.activate() } }) {
        self.activate = activate
    }

    /// The overlay options for `scope`.
    public static func options(for scope: CmuxDialogScope) -> OverlayOptions {
        switch scope {
        case .tab(let view):
            let rect = view.window == nil ? view.bounds : view.convert(view.bounds, to: nil)
            return OverlayOptions(kind: .dialog, anchor: rect, isModal: true, dismissOnEscape: false, dimsContent: false,
                                  passesThroughClicks: false, modalRegion: rect)
        case .window, .app:
            return OverlayOptions(kind: .dialog, isModal: true, dismissOnEscape: false, dimsContent: true, passesThroughClicks: false)
        }
    }

    public func show(_ dialog: CmuxDialogView, in scope: CmuxDialogScope, scopeGone: @escaping () -> Void) {
        dialog.layoutSubtreeIfNeeded()
        let size = dialog.fittingSize
        dialog.translatesAutoresizingMaskIntoConstraints = true
        dialog.frame = NSRect(origin: .zero, size: size)
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
                guard let entry, let rect = entry.watcher?.windowRect else { return }
                entry.handle?.update(anchor: rect, modalRegion: rect)
            }
            entry.watcher = watcher
        }
        sync(entry)
    }

    public func hide(_ dialog: CmuxDialogView) {
        guard let entry = shown.removeValue(forKey: ObjectIdentifier(dialog)) else { return }
        entry.watcher?.stop()
        detach(entry)
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
            if entry.handle == nil, !NSApp.isActive { activate() }
        }
        guard let host else { return detach(entry) }
        if let handle = entry.handle, !handle.isDismissed, handle.host === host { return }
        detach(entry)
        let handle = host.present(entry.dialog, options: Self.options(for: scope))
        // The window closed (its host dismissed every overlay): the dialog ends.
        handle.onDismiss = entry.scopeGone
        entry.handle = handle
        entry.dialog.focusInitial()
    }

    private func detach(_ entry: Shown) {
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
