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
    private var handles: [ObjectIdentifier: (handle: OverlayHandle, window: NSWindow, view: CmuxToastView, slot: Int)] = [:]
    private var avoidanceObserver: (any NSObjectProtocol)?

    public init() {
        avoidanceObserver = NotificationCenter.default.addObserver(forName: .cmuxToastAvoidanceDidChange, object: nil,
                                                                   queue: .main) { [weak self] _ in
            // task-owner: one hop to the main actor; moves this host's toasts once
            Task { @MainActor in self?.reanchor(in: nil) }
        }
    }

    isolated deinit {
        if let avoidanceObserver { NotificationCenter.default.removeObserver(avoidanceObserver) }
    }

    /// The overlay places a toast 24 pt above the anchor's bottom, centered.
    static let overlayLift: CGFloat = 24

    /// The anchor of `slot` in window coordinates, its toast's bottom at
    /// `floor` or higher (clear of the views toasts avoid).
    static func anchor(slot: Int, height: CGFloat, in bounds: NSRect, floor: CGFloat? = nil) -> NSRect {
        let base = max(bounds.minY, (floor ?? bounds.minY) - overlayLift)
        return NSRect(x: bounds.minX, y: base + CGFloat(slot) * (height + 8), width: bounds.width, height: height)
    }

    private func anchor(for toast: CmuxToastView, slot: Int, in window: NSWindow) -> NSRect {
        let bounds = window.contentView?.bounds ?? .zero
        return Self.anchor(slot: slot, height: toast.frame.height, in: bounds,
                           floor: Self.floor(width: toast.frame.width, in: bounds, window: window))
    }

    /// Moves every toast in `window` (all windows when nil) clear of the avoided views.
    private func reanchor(in window: NSWindow?) {
        for entry in handles.values where window == nil || entry.window === window {
            entry.handle.update(anchor: anchor(for: entry.view, slot: entry.slot, in: entry.window))
        }
    }

    public func show(_ toast: CmuxToastView, in window: NSWindow, slot: Int, windowGone: @escaping () -> Void) {
        toast.layoutSubtreeIfNeeded()
        let size = toast.fittingSize
        toast.translatesAutoresizingMaskIntoConstraints = true
        toast.frame = NSRect(origin: .zero, size: size)
        let options = OverlayOptions(kind: .toast, anchor: anchor(for: toast, slot: slot, in: window),
                                     passesThroughClicks: false)
        let handle = WindowOverlayHost.host(for: window).present(toast, options: options)
        handle.onDismiss = windowGone
        handles[ObjectIdentifier(toast)] = (handle, window, toast, slot)
    }

    public func move(_ toast: CmuxToastView, to slot: Int) {
        guard var entry = handles[ObjectIdentifier(toast)] else { return }
        entry.slot = slot
        handles[ObjectIdentifier(toast)] = entry
        entry.handle.update(anchor: anchor(for: toast, slot: slot, in: entry.window))
    }

    public func hide(_ toast: CmuxToastView) {
        guard let (handle, _, _, _) = handles.removeValue(forKey: ObjectIdentifier(toast)) else { return }
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
