public import AppKit

/// The in-window backend of the overlay host (in-tree pages, ``InTreePages``).
///
/// With pages in the window's own view tree nothing draws above the window's views, so the host needs no panel: the
/// panel's root (``OverlayHostPanel/root``, the planes and the three overlay containers) moves onto the top of the main
/// window's content view, in window coordinates, and stays the content view's last subview. Every presenter keeps its
/// API and its coordinates (the panel's were the window's). The mouse goes by AppKit's own hit test
/// (``OverlayRootView``): no mouse monitor, no `ignoresMouseEvents` switching, no event taken from below. The window
/// stays key: a modal overlay takes the window's first responder (through the window's gate), Tab cycles inside it
/// (`ShellWindow.selectNextKeyView`), and its key equivalents go only to it (`ShellWindow.performKeyEquivalent`).
extension WindowOverlayHost {
    /// Whether this host puts its overlays on the window itself (in-tree pages on, never the app host), unless a page
    /// window is on screen over the window (``servesPageWindows``): views on the window would draw and take the mouse
    /// under it, so the overlays go back to the panel above it.
    public var usesWindowBackend: Bool { !isAppHost && InTreePages.shared.isActive && !servesPageWindows }

    /// Whether the overlay root is on the window's content view now.
    public var isRootInWindow: Bool {
        guard let window, let content = window.contentView else { return false }
        return panel.root.inWindow && panel.root.superview === content
    }

    /// The window whose first responder the overlays' controls are: the window itself in-window, else the panel.
    var responderWindow: NSWindow? { usesWindowBackend ? window : panel }

    /// Makes `responder` the first responder of the overlays' window: through the window's gate in-window (a modal
    /// overlay's control), else the panel's own.
    @discardableResult
    func makeOverlayFirstResponder(_ responder: NSResponder?) -> Bool {
        guard usesWindowBackend else { return panel.makeFirstResponder(responder) }
        return FocusRoute(.person, "an overlay takes the keyboard").moveKeyboard(in: window, to: responder)
    }

    /// Puts the root on the window (`wanted`) or takes it off; the in-window form of attaching the panel.
    func syncInWindowRoot(wanted: Bool) {
        guard let window, let content = window.contentView else { return }
        let root = panel.root
        if wanted {
            if panel.contentView === root {
                // The panel keeps an empty content view; it never orders in while the window backend is on.
                panel.contentView = NSView()
            }
            root.inWindow = true
            root.acceptsMouse = { [weak self] point in self?.acceptsMouse(at: point) ?? false }
            let frame = content.convert(NSRect(origin: .zero, size: window.frame.size), from: nil)
            if root.frame != frame { root.frame = frame }
            raiseRootIfNeeded()
            if windowObservers.isEmpty { observeWindow(window) }
        } else if root.superview != nil, root.inWindow {
            root.removeFromSuperview()
            stopObservingWindow()
        }
    }

    /// The window backend went off (an engine without the in-tree calls): the root goes back into the panel.
    func returnRootToPanel() {
        let root = panel.root
        guard root.inWindow else { return }
        root.removeFromSuperview()
        root.inWindow = false
        root.frame = panel.contentView?.frame ?? .zero
        panel.contentView = root
        stopObservingWindow()
    }

    /// Keeps the root the content view's last subview: a view added later (a sheet host, the sidebar) would cover
    /// the overlays (`WindowRootView` calls this on every add and reorder).
    @discardableResult
    func raiseRootIfNeeded() -> Bool {
        guard let window, let content = window.contentView, panel.root.inWindow, content.subviews.last !== panel.root
        else { return false }
        content.addSubview(panel.root, positioned: .above, relativeTo: nil)
        return true
    }

    /// Whether `view` is one of this window's in-window overlays (a modal's control): the window's focus model does
    /// not hear of a first responder there, as it did not while the panel held it.
    public static func isInWindowOverlayView(_ view: NSView?, in window: NSWindow) -> Bool {
        guard let view, let host = existingHost(for: window), host.isRootInWindow else { return false }
        return view.isDescendant(of: host.panel.root)
    }

    /// The newest modal overlay shown on `window` itself (in-window), if any.
    public static func inWindowModalContent(of window: NSWindow) -> NSView? {
        guard let host = existingHost(for: window), host.isRootInWindow else { return nil }
        return host.handles.last(where: { $0.options.isModal })?.content
    }

    /// Tab (`forward`) or Shift-Tab in `window` while an in-window modal overlay shows: true when the overlay took it.
    public static func cycleInWindowModal(of window: NSWindow, forward: Bool) -> Bool {
        guard let host = existingHost(for: window), host.isRootInWindow else { return false }
        return host.cycleKeyView(forward: forward)
    }

    /// An Escape for an in-window modal: its own key equivalent (a Cancel button) first, else the newest overlay that
    /// dismisses on Escape goes. A composition in a field of the overlay keeps its Escape.
    func routeInWindowModalEscape(_ event: NSEvent, top: OverlayHandle) -> Bool {
        if !((window?.firstResponder as? NSView)?.isDescendant(of: top.content) ?? false) {
            makeOverlayFirstResponder(Self.keyViews(in: top.content).first ?? top.content)
        }
        if let text = window?.firstResponder as? NSTextView, text.hasMarkedText() { return false }
        if top.content.performKeyEquivalent(with: event) { return true }
        escape()
        return true
    }
}
