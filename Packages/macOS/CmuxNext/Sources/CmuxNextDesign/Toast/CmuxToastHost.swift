public import AppKit

/// Places toast views at the bottom of a window, slot 0 lowest.
@MainActor
public protocol CmuxToastHosting: AnyObject {
    /// `windowGone` runs if the window closes while the toast shows.
    /// `appearing` false shows it in place at once (it takes a shown toast's slot).
    func show(_ toast: CmuxToastView, in window: NSWindow, slot: Int, appearing: Bool, windowGone: @escaping () -> Void)
    func move(_ toast: CmuxToastView, to slot: Int)
    /// `animated` false removes it at once (a newer toast took its place).
    func hide(_ toast: CmuxToastView, animated: Bool)
    /// The window's toasts reached their slots (after a show, an end or a resize): the views that
    /// reserve room for them (``CmuxToastReserving``) keep their content clear of them.
    func settled(in window: NSWindow)
}

extension CmuxToastHosting {
    public func settled(in window: NSWindow) {}
}

/// Toasts on the R84 `WindowOverlayHost` (`.toast` kind): above every page,
/// taking clicks only on the toast itself.
@MainActor
public final class CmuxToastOverlayHost: CmuxToastHosting, CmuxToastReanchoring {
    private var handles: [ObjectIdentifier: (handle: OverlayHandle, window: NSWindow, view: CmuxToastView, slot: Int)] = [:]

    public init() {}

    /// The overlay places a toast 24 pt above the anchor's bottom, centered.
    static let overlayLift: CGFloat = 24

    /// The gap between two stacked toasts.
    static let stackGap: CGFloat = 8

    /// The anchor of `slot` in window coordinates, its toast's bottom at
    /// `floor` or higher (clear of the views toasts avoid). `below`: the
    /// heights of the toasts in the lower slots; nil takes each as tall as
    /// this one.
    static func anchor(slot: Int, height: CGFloat, in bounds: NSRect, floor: CGFloat? = nil, below: [CGFloat]? = nil) -> NSRect {
        let base = max(bounds.minY, (floor ?? bounds.minY) - overlayLift)
        let lift = below.map { $0.reduce(0) { $0 + $1 + stackGap } } ?? CGFloat(slot) * (height + stackGap)
        return NSRect(x: bounds.minX, y: base + lift, width: bounds.width, height: height)
    }

    private func anchor(for toast: CmuxToastView, slot: Int, in window: NSWindow) -> NSRect {
        let bounds = window.contentView?.bounds ?? .zero
        // A toast showing its details is taller: the ones above it stack on its real height. A slot
        // with no toast (one pushed out moves past the stack before its successor shows) or several
        // (mid-restack) takes the tallest there, else this toast's height, as before.
        let others = handles.values.filter { $0.window === window && $0.view !== toast }
        let below = (0..<max(slot, 0)).map { lower in
            others.filter { $0.slot == lower }.map(\.view.frame.height).max() ?? toast.frame.height
        }
        return Self.anchor(slot: slot, height: toast.frame.height, in: bounds,
                           floor: Self.floor(width: toast.frame.width, in: bounds, window: window), below: below)
    }

    /// Moves every toast in `window` clear of the avoided views, sliding from where it is drawn
    /// as a restack does (``CmuxToastAvoidance/avoidanceChanged(in:)`` calls it for its window).
    func reanchor(in window: NSWindow) {
        for entry in handles.values where entry.window === window {
            CmuxToastMotion.move(entry.view) {
                entry.handle.update(anchor: anchor(for: entry.view, slot: entry.slot, in: entry.window))
            }
        }
        settled(in: window)
    }

    /// Tells every view in `window` that reserves room for toasts where this host's toasts now
    /// rest (nil: none), with the toasts' move time.
    public func settled(in window: NSWindow) {
        let rect = toastsRect(in: window)
        let duration = Motion.overlays.animatesMovement ? Motion.overlays.duration(.move) : 0
        Self.reservingViews(in: window).forEach { $0.toastsSettled(in: rect, duration: duration) }
    }

    func settled(in window: NSWindow, only view: any CmuxToastReserving) {
        view.toastsSettled(in: toastsRect(in: window), duration: 0)
    }

    /// The union of this host's toast frames in `window` (window coordinates); nil when none shows.
    private func toastsRect(in window: NSWindow) -> NSRect? {
        // The overlay panel's coordinates are the window's own (WindowOverlayHost.layout).
        let frames = handles.values.filter { $0.window === window && $0.view.window != nil }
            .map { $0.view.convert($0.view.bounds, to: nil) }
        return frames.dropFirst().reduce(frames.first) { $0?.union($1) }
    }

    /// Every view under `window`'s content view that reserves room for toasts, hidden ones too
    /// (one hidden while toasts showed still hears that they went).
    static func reservingViews(in window: NSWindow) -> [any CmuxToastReserving] {
        var found: [any CmuxToastReserving] = []
        var pending: [NSView] = window.contentView.map { [$0] } ?? []
        while let view = pending.popLast() {
            if let reserving = view as? any CmuxToastReserving { found.append(reserving) }
            pending.append(contentsOf: view.subviews)
        }
        return found
    }

    public func show(_ toast: CmuxToastView, in window: NSWindow, slot: Int, appearing: Bool, windowGone: @escaping () -> Void) {
        toast.layoutSubtreeIfNeeded()
        let size = toast.fittingSize
        toast.translatesAutoresizingMaskIntoConstraints = true
        toast.frame = NSRect(origin: .zero, size: size)
        let options = OverlayOptions(kind: .toast, anchor: anchor(for: toast, slot: slot, in: window),
                                     passesThroughClicks: false)
        let handle = WindowOverlayHost.host(for: window).present(toast, options: options)
        handle.onDismiss = windowGone
        // The window's host observes its geometry once; the toast re-caps its shown detail from it.
        handle.onWindowGeometryChange = { [weak toast] in toast?.windowGeometryDidChange() }
        handles[ObjectIdentifier(toast)] = (handle, window, toast, slot)
        // This window's avoided views now move this host's toasts there (and no other window's).
        CmuxToastAvoidance.register(self, in: window)
        if appearing { CmuxToastMotion.appear(toast) }
    }

    public func move(_ toast: CmuxToastView, to slot: Int) {
        guard var entry = handles[ObjectIdentifier(toast)] else { return }
        entry.slot = slot
        handles[ObjectIdentifier(toast)] = entry
        CmuxToastMotion.move(toast) { entry.handle.update(anchor: anchor(for: toast, slot: slot, in: entry.window)) }
    }

    public func hide(_ toast: CmuxToastView, animated: Bool) {
        guard let (handle, window, _, _) = handles.removeValue(forKey: ObjectIdentifier(toast)) else { return }
        handle.onDismiss = nil
        // Its last toast in the window gone, this host stops moving toasts there (a closed window
        // ends its toasts through here too, via `windowGone`).
        if !handles.values.contains(where: { $0.window === window }) {
            CmuxToastAvoidance.unregister(self, from: window)
        }
        // While it fades, the page under it gets the next click.
        handle.stopTakingMouse()
        CmuxToastMotion.disappear(toast, animated: animated) { handle.dismiss() }
    }
}
