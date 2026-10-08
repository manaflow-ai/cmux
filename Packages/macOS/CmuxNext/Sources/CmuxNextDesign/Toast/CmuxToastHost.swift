public import AppKit

/// Places toast views at the bottom of a window, slot 0 lowest.
@MainActor
public protocol CmuxToastHosting: AnyObject {
    /// `windowGone` runs if the window closes while the toast shows.
    func show(_ toast: CmuxToastView, in window: NSWindow, slot: Int, windowGone: @escaping () -> Void)
    func move(_ toast: CmuxToastView, to slot: Int)
    func hide(_ toast: CmuxToastView)
}

/// Toasts on the R84 `WindowOverlayHost` (`.toast` kind): above every page,
/// taking clicks only on the toast itself.
@MainActor
public final class CmuxToastOverlayHost: CmuxToastHosting {
    private var handles: [ObjectIdentifier: (handle: OverlayHandle, window: NSWindow)] = [:]

    public init() {}

    /// The anchor of `slot` in window coordinates: the overlay places a
    /// toast 24 pt above the anchor's bottom, centered.
    static func anchor(slot: Int, height: CGFloat, in bounds: NSRect) -> NSRect {
        NSRect(x: bounds.minX, y: bounds.minY + CGFloat(slot) * (height + 8), width: bounds.width, height: height)
    }

    public func show(_ toast: CmuxToastView, in window: NSWindow, slot: Int, windowGone: @escaping () -> Void) {
        toast.layoutSubtreeIfNeeded()
        let size = toast.fittingSize
        toast.translatesAutoresizingMaskIntoConstraints = true
        toast.frame = NSRect(origin: .zero, size: size)
        let bounds = window.contentView?.bounds ?? .zero
        let options = OverlayOptions(kind: .toast, anchor: Self.anchor(slot: slot, height: size.height, in: bounds),
                                     passesThroughClicks: false)
        let handle = WindowOverlayHost.host(for: window).present(toast, options: options)
        handle.onDismiss = windowGone
        handles[ObjectIdentifier(toast)] = (handle, window)
    }

    public func move(_ toast: CmuxToastView, to slot: Int) {
        guard let (handle, window) = handles[ObjectIdentifier(toast)] else { return }
        handle.update(anchor: Self.anchor(slot: slot, height: toast.frame.height, in: window.contentView?.bounds ?? .zero))
    }

    public func hide(_ toast: CmuxToastView) {
        guard let (handle, _) = handles.removeValue(forKey: ObjectIdentifier(toast)) else { return }
        handle.onDismiss = nil
        handle.dismiss()
    }
}

/// Keeps toasts off screen (tests, headless automation) and records their
/// slots; `closeWindow()` acts as if the window closed.
@MainActor
public final class CmuxToastHeadlessHost: CmuxToastHosting {
    private var shown: [(view: CmuxToastView, slot: Int, gone: () -> Void)] = []

    public init() {}

    /// The toasts showing, bottom slot first.
    public var slots: [CmuxToast] { shown.sorted { $0.slot < $1.slot }.map(\.view.toast) }

    public func show(_ toast: CmuxToastView, in window: NSWindow, slot: Int, windowGone: @escaping () -> Void) {
        shown.append((toast, slot, windowGone))
    }

    public func move(_ toast: CmuxToastView, to slot: Int) {
        if let index = shown.firstIndex(where: { $0.view === toast }) { shown[index].slot = slot }
    }

    public func hide(_ toast: CmuxToastView) {
        shown.removeAll { $0.view === toast }
    }

    public func closeWindow() {
        shown.first?.gone()
    }
}
