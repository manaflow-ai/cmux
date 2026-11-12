public import AppKit

/// Draws each window's toasts as native views (``CmuxToastView``, on the toast role's glass) on the
/// window's R84 `WindowOverlayHost` (`.toast`): above every page, bottom-center, the newest lowest,
/// taking clicks only on the toasts themselves.
///
/// The center owns which toasts show, their order, timers and state (``CmuxToastCenter``); this host
/// moves its views from what it shows to what the center says, with the toasts' motion
/// (``CmuxToastMotion``): a new toast rises and fades in, one that stays slides to its new slot, one
/// that ends fades where it is, and a toast replaced under its id is swapped in one frame.
///
/// Toasts never cover what they avoid (``CmuxToastAvoiding``: the agent chat's composer, which
/// never moves for a toast, #37545): each toast rests above every avoided view under it, and moves
/// when one changes (``reanchor(in:)``). The views that reserve room (``CmuxToastReserving``) hear
/// where the toasts rest whenever that changes.
///
/// ```swift
/// let toasts = CmuxToastOverlayHost(drawing: .shared) // the composition root, once
/// ```
@MainActor
public final class CmuxToastOverlayHost: CmuxToastHosting, CmuxToastReanchoring {
    /// One toast this host draws.
    private struct Entry {
        let serial: Int
        let view: CmuxToastView
        let handle: OverlayHandle
    }

    /// One window's toasts.
    private final class Stack {
        weak var window: NSWindow?
        weak var center: CmuxToastCenter?
        /// The toasts that show, oldest first (the newest rests lowest).
        var entries: [Entry] = []
        /// Toasts fading out, still drawn: the room under them is kept until their fade ends.
        var fading: [ObjectIdentifier: CmuxToastView] = [:]

        init(window: NSWindow) { self.window = window }
    }

    private var stacks: [ObjectIdentifier: Stack] = [:]
    private let reduceTransparency: ReduceTransparency

    /// - Parameter reduceTransparency: Decides glass or the opaque surface for every toast (tests
    ///   pass their own).
    public init(reduceTransparency: ReduceTransparency = .shared) {
        self.reduceTransparency = reduceTransparency
    }

    /// Draws `center`'s toasts from now on (the composition root makes one, for the shared center).
    public convenience init(drawing center: CmuxToastCenter) {
        self.init()
        center.host = self
    }

    /// The overlay places a toast 24 pt above the anchor's bottom, centered.
    static let overlayLift: CGFloat = 24

    /// The gap between two stacked toasts.
    static let stackGap: CGFloat = 8

    // MARK: Layout math

    /// The anchor (window coordinates) of a toast of `height` whose lower neighbors are `below`
    /// tall: the overlay rests it ``overlayLift`` above the anchor's bottom, so its bottom edge is
    /// at `floor` or higher (clear of the views toasts avoid; nil: the content's bottom), never
    /// under the lift above the content's bottom, and above the toasts below it, a gap apart.
    static func anchor(height: CGFloat, in bounds: NSRect, floor: CGFloat? = nil, below: [CGFloat] = []) -> NSRect {
        let base = max(bounds.minY, (floor ?? bounds.minY) - overlayLift)
        let lift = below.reduce(0) { $0 + $1 + stackGap }
        return NSRect(x: bounds.minX, y: base + lift, width: bounds.width, height: height)
    }

    /// The anchors of a stack of toasts of `sizes`, oldest first, in `bounds`: the newest (last)
    /// rests lowest and each older one above it. `floor` gives the lowest bottom edge a toast of
    /// a width may take.
    static func anchors(sizes: [NSSize], in bounds: NSRect, floor: (CGFloat) -> CGFloat) -> [NSRect] {
        sizes.indices.map { index in
            anchor(height: sizes[index].height, in: bounds, floor: floor(sizes[index].width),
                   below: sizes[(index + 1)...].map(\.height))
        }
    }

    private func anchors(of stack: Stack, in window: NSWindow) -> [NSRect] {
        let bounds = window.contentView?.bounds ?? .zero
        return Self.anchors(sizes: stack.entries.map(\.view.frame.size), in: bounds) {
            CmuxToastAvoidance.floor(width: $0, in: bounds, window: window)
        }
    }

    // MARK: CmuxToastHosting

    public func show(_ toasts: [CmuxToastShown], in window: NSWindow, center: CmuxToastCenter) {
        let key = ObjectIdentifier(window)
        let stack: Stack
        if let existing = stacks[key], existing.window === window {
            stack = existing
        } else {
            guard !toasts.isEmpty else { return }
            stack = Stack(window: window)
            stacks[key] = stack
        }
        stack.center = center

        let wanted = Set(toasts.map(\.serial))
        let known = Set(stack.entries.map(\.serial))
        let arriving = toasts.filter { !known.contains($0.serial) }
        let leaving = stack.entries.filter { !wanted.contains($0.serial) }
        let previousNewest = stack.entries.last
        var kept = Dictionary(stack.entries.filter { wanted.contains($0.serial) }.map { ($0.serial, $0) }) { first, _ in first }

        // A same-id predecessor goes in this frame: its successor takes its place, and two
        // different toasts never crossfade. One that ended (its time, its close button, pushed
        // over the limit) fades once the stack has its final heights.
        let arrivingIDs = Set(arriving.map(\.toast.id))
        let swapped = leaving.filter { arrivingIDs.contains($0.view.toast.id) }
        let ended = leaving.filter { !arrivingIDs.contains($0.view.toast.id) }
        for entry in swapped { hide(entry, from: stack, in: window, animated: false) }

        // Sizes first (a toast with its details shown is taller), then every toast's slot.
        var presented: [(shown: CmuxToastShown, view: CmuxToastView)] = []
        var entries: [Entry?] = []
        for shown in toasts {
            if let entry = kept.removeValue(forKey: shown.serial) {
                entry.view.showsUndoKey = shown.showsUndoKey
                if entry.view.showsDetails != shown.showsDetails {
                    entry.view.setShowsDetails(shown.showsDetails)
                    size(entry.view)
                }
                entries.append(entry)
            } else {
                let view = makeView(shown, in: window)
                presented.append((shown, view))
                entries.append(nil)
            }
        }
        // One pushed out fades a slot above the stack, clear of the toast moving into its slot.
        if !arriving.isEmpty, !ended.isEmpty {
            let bounds = window.contentView?.bounds ?? .zero
            let heights = presented.map(\.view.frame.height) + entries.compactMap { $0?.view.frame.height }
            for entry in ended {
                let anchor = Self.anchor(height: entry.view.frame.height, in: bounds,
                                         floor: CmuxToastAvoidance.floor(width: entry.view.frame.width, in: bounds, window: window),
                                         below: heights)
                CmuxToastMotion.move(entry.view) { entry.handle.update(anchor: anchor) }
            }
        }
        // A successor of the newest toast shows in its slot at once, so a repeated toast never
        // blinks out and fades back in.
        let inPlace = previousNewest.map { old in swapped.contains { $0.serial == old.serial } } ?? false
        var pending = presented.makeIterator()
        stack.entries = []
        var fresh: [Entry] = []
        for entry in entries {
            if let entry {
                stack.entries.append(entry)
            } else if let (shown, view) = pending.next() {
                let entry = present(view, serial: shown.serial, stack: stack, in: window)
                stack.entries.append(entry)
                fresh.append(entry)
            }
        }
        let placed = anchors(of: stack, in: window)
        for (entry, anchor) in zip(stack.entries, placed) {
            if fresh.contains(where: { $0.serial == entry.serial }) {
                entry.handle.update(anchor: anchor)
                if !(inPlace && entry.serial == toasts.last?.serial) { CmuxToastMotion.appear(entry.view) }
            } else {
                CmuxToastMotion.move(entry.view) { entry.handle.update(anchor: anchor) }
            }
        }
        for entry in ended { hide(entry, from: stack, in: window, animated: true) }

        if !stack.entries.isEmpty {
            // A toast swapped in for the window's only toast: its predecessor's end retired the stack.
            stacks[key] = stack
            CmuxToastAvoidance.register(self, in: window)
        }
        // The toasts moved under a possibly still pointer: a hovered toast that moved away loses
        // its hold and its timer starts again (cx-3wu5). Window-wide: the toasts' buttons moved too.
        PointerHover.refresh(in: stack.entries.lazy.compactMap(\.view.window).first)
        // A toast that appears under a still pointer holds at once.
        for entry in fresh where entry.view.isHovered { center.pointer(onToast: entry.serial, true) }
        settled(in: window)
        retireIfEmpty(stack, in: window)
    }

    private func makeView(_ shown: CmuxToastShown, in window: NSWindow) -> CmuxToastView {
        let view = CmuxToastView(toast: shown.toast, reduceTransparency: reduceTransparency)
        view.showsUndoKey = shown.showsUndoKey
        if shown.showsDetails { view.setShowsDetails(true) }
        size(view)
        return view
    }

    /// Gives `view` its fitting size (its frame places it; the overlay keeps a content's size).
    private func size(_ view: CmuxToastView) {
        view.layoutSubtreeIfNeeded()
        let size = view.fittingSize
        view.translatesAutoresizingMaskIntoConstraints = true
        view.setFrameSize(size)
    }

    /// Puts `view` on the window's overlay and wires its buttons and pointer to the center.
    private func present(_ view: CmuxToastView, serial: Int, stack: Stack, in window: NSWindow) -> Entry {
        view.onAction = { [weak stack] in stack?.center?.personRanAction(serial: serial) }
        view.onClose = { [weak stack] in stack?.center?.personClosed(serial: serial) }
        view.onHover = { [weak stack] hovered in stack?.center?.pointer(onToast: serial, hovered) }
        let options = OverlayOptions(kind: .toast, anchor: window.contentView?.bounds, passesThroughClicks: false)
        let handle = WindowOverlayHost.host(for: window).present(view, options: options)
        // The window closed: its toasts end with it.
        handle.onDismiss = { [weak self, weak window, weak stack] in
            guard let self, let window, let stack else { return }
            stack.entries.removeAll { $0.serial == serial }
            stack.center?.windowClosed(window)
            self.retireIfEmpty(stack, in: window)
        }
        // The overlay observes its window once; the toasts follow its new size in the same frame,
        // and so do the views under them.
        handle.onWindowGeometryChange = { [weak self, weak window, weak stack] in
            guard let self, let window, let stack, stack.entries.last?.serial == serial else { return }
            self.relayout(stack, in: window, sizing: true, animated: false)
        }
        return Entry(serial: serial, view: view, handle: handle)
    }

    /// Ends `entry`'s drawing: at once, or with its fade. While it fades, the page under it gets
    /// the next click; the room under it stays until it is gone, then the views under it take that
    /// room back.
    private func hide(_ entry: Entry, from stack: Stack, in window: NSWindow, animated: Bool) {
        stack.entries.removeAll { $0.serial == entry.serial }
        let handle = entry.handle
        handle.onDismiss = nil
        handle.onWindowGeometryChange = nil
        handle.stopTakingMouse()
        entry.view.onAction = nil
        entry.view.onClose = nil
        let key = ObjectIdentifier(entry.view)
        stack.fading[key] = entry.view
        CmuxToastMotion.disappear(entry.view, animated: animated) { [weak self, weak window, weak stack] in
            handle.dismiss()
            guard let self, let stack, stack.fading.removeValue(forKey: key) != nil, let window else { return }
            self.settled(in: window)
            self.retireIfEmpty(stack, in: window)
        }
    }

    /// Places every toast of `stack` again: `sizing` first gives each its fitting size (the window
    /// resized: a shown detail is capped again); `animated` slides them from where they are drawn.
    private func relayout(_ stack: Stack, in window: NSWindow, sizing: Bool, animated: Bool) {
        if sizing {
            for entry in stack.entries {
                entry.view.windowGeometryDidChange()
                size(entry.view)
            }
        }
        for (entry, anchor) in zip(stack.entries, anchors(of: stack, in: window)) {
            if animated {
                CmuxToastMotion.move(entry.view) { entry.handle.update(anchor: anchor) }
            } else {
                entry.handle.update(anchor: anchor)
            }
        }
        settled(stack, in: window, duration: animated ? Self.moveDuration : 0)
    }

    /// The window's last toast is gone and none still fades: this host stops moving toasts there.
    private func retireIfEmpty(_ stack: Stack, in window: NSWindow) {
        guard stack.entries.isEmpty else { return }
        CmuxToastAvoidance.unregister(self, from: window)
        guard stack.fading.isEmpty, stacks[ObjectIdentifier(window)] === stack else { return }
        stacks[ObjectIdentifier(window)] = nil
    }

    // MARK: Reserving and avoiding

    /// How long the toasts take to reach their slots; the views under them move over the same time.
    private static var moveDuration: TimeInterval {
        Motion.overlays.animatesMovement ? Motion.overlays.duration(.move) : 0
    }

    /// The union of this host's drawn toast frames in `window` (window coordinates), fading ones
    /// included; nil when none shows.
    func toastsRect(in window: NSWindow) -> NSRect? {
        guard let stack = stacks[ObjectIdentifier(window)], stack.window === window else { return nil }
        // The overlay panel's coordinates are the window's own (WindowOverlayHost.layout).
        let views = stack.entries.map(\.view) + Array(stack.fading.values)
        let frames = views.filter { $0.window != nil }.map { $0.convert($0.bounds, to: nil) }
        return frames.dropFirst().reduce(frames.first) { $0?.union($1) }
    }

    /// The frames (window coordinates) of the toasts this host shows in `window`, oldest first,
    /// fading ones left out.
    func toastFrames(in window: NSWindow) -> [NSRect] {
        guard let stack = stacks[ObjectIdentifier(window)], stack.window === window else { return [] }
        return stack.entries.map { $0.view.convert($0.view.bounds, to: nil) }
    }

    /// Tells every view in `window` that reserves room for toasts where this host's toasts now
    /// rest (nil: none), with the toasts' move time.
    public func settled(in window: NSWindow) {
        guard let stack = stacks[ObjectIdentifier(window)], stack.window === window else { return }
        settled(stack, in: window, duration: Self.moveDuration)
    }

    private func settled(_ stack: Stack, in window: NSWindow, duration: TimeInterval) {
        let rect = toastsRect(in: window)
        CmuxToastAvoidance.reservingViews(in: window).forEach { $0.toastsSettled(in: rect, duration: duration) }
    }

    public func settled(in window: NSWindow, only view: any CmuxToastReserving) {
        view.toastsSettled(in: toastsRect(in: window), duration: 0)
    }

    /// Moves every toast in `window` clear of the avoided views, sliding from where it is drawn
    /// as a restack does (``CmuxToastAvoidance/avoidanceChanged(in:)`` calls it for its window).
    public func reanchor(in window: NSWindow) {
        guard let stack = stacks[ObjectIdentifier(window)], stack.window === window else { return }
        relayout(stack, in: window, sizing: false, animated: true)
    }
}
