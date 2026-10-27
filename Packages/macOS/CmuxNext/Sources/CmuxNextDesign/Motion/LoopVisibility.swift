public import AppKit
public import CmuxNextWakeups
public import QuartzCore

/// The one way a view runs an infinite Core Animation loop: the loop is in the render server only
/// while a person can see it (plans/cmux-next/chrome-parity/p03-rendering.md, R6 and task 070).
///
/// Its ``node`` sits under the view's window node (``WindowVisibilitySource``: occluded while AppKit
/// says so or while the window's ``WindowOcclusionFamily`` does, which covers a window fully under
/// an opaque cmux window of the same size, crbug.com/883031), or under a hidden root while the view
/// is in no window; its own state is the view's hidden state. While the node is not ``Visibility/visible`` (the view left its window, it or
/// an ancestor is hidden, the window is miniaturized or occluded, the app is hidden) no attached loop
/// is on its layer. When the node shows again each loop is made again and begins at the phase the
/// shared media-time clock gives it (``SpinnerClock``), so it joins in step instead of restarting.
/// Chromium stops the same work for a hidden or occluded WebContents: `WebContentsImpl::WasHidden`
/// and `WasOccluded` stop the compositor's begin frames (`content/browser/web_contents/web_contents_impl.cc`),
/// and `cc/animation` ticks no animation while the layer tree host is not visible.
///
/// ```swift
/// let loops = LoopVisibility("nightSky")
/// override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); loops.place(in: window) }
/// override func viewDidHide() { super.viewDidHide(); loops.node.set(.hidden) }
/// override func viewDidUnhide() { super.viewDidUnhide(); loops.node.set(.visible) }
/// loops.attach(star, key: "twinkle") { Motion.panes.spinAnimation() }
/// ```
@MainActor public final class LoopVisibility {
    /// Makes the loop, or nil when loops are off (Reduce Motion, Energy Saver, the category off).
    public typealias Make = @MainActor () -> CAAnimation?

    /// The view's place in the visibility tree: its loops run only while it is visible.
    public var node: VisibilityNode { view.node }

    private let view: ViewVisibility
    private let clock: SpinnerClock
    private var loops: [LoopKey: Loop] = [:]
    /// Held only while a loop is attached, so a view with no loop costs its node no subscriber.
    private var flips: VisibilitySubscription?

    private struct LoopKey: Hashable {
        let layer: ObjectIdentifier
        let key: String
    }

    private struct Loop {
        weak var layer: CALayer?
        let key: String
        let make: Make
    }

    /// - Parameters:
    ///   - name: The node's name in diagnostics (`nightSky`, `sidebar.row.wiggle`).
    ///   - clock: The media-time clock a loop's phase is counted from; tests pass fixed times.
    public init(_ name: String, clock: SpinnerClock = SpinnerClock()) {
        view = ViewVisibility(name)
        self.clock = clock
    }

    /// Puts ``node`` under `window`'s node, or under the hidden root for no window. The view calls it
    /// from `viewDidMoveToWindow`; its `viewDidHide` / `viewDidUnhide` set ``node`` hidden / visible
    /// (recipe R-hide, plans/cmux-next/chrome-parity/p06-scheduler.md).
    /// - Parameter window: The view's window.
    public func place(in window: NSWindow?) {
        view.place(in: window)
    }

    /// Runs `make`'s loop on `layer` under `key` whenever ``node`` is visible, replacing any loop
    /// attached there before. Visible now, the loop starts in this turn.
    /// - Parameters:
    ///   - layer: The layer the loop animates (held weakly).
    ///   - key: The animation key on `layer`.
    ///   - make: Makes the loop each time it starts, so it follows the motion settings of that moment.
    public func attach(_ layer: CALayer, key: String, make: @escaping Make) {
        loops[LoopKey(layer: ObjectIdentifier(layer), key: key)] = Loop(layer: layer, key: key, make: make)
        follow()
        layer.removeAnimation(forKey: key)
        if node.isVisible { start(layer, key: key, make: make) }
    }

    /// Takes the loop under `key` off `layer` for good.
    public func detach(_ layer: CALayer, key: String) {
        loops[LoopKey(layer: ObjectIdentifier(layer), key: key)] = nil
        layer.removeAnimation(forKey: key)
        follow()
    }

    /// Takes every attached loop off.
    public func detachAll() {
        for loop in loops.values { loop.layer?.removeAnimation(forKey: loop.key) }
        loops.removeAll()
        follow()
    }

    /// Whether a loop is attached to `layer` under `key` (running or waiting to show).
    public func isAttached(_ layer: CALayer, key: String) -> Bool {
        loops[LoopKey(layer: ObjectIdentifier(layer), key: key)] != nil
    }

    /// The attached loops that are on their layers now: 0 while ``node`` is not visible.
    public var runningCount: Int {
        loops.values.filter { loop in loop.layer?.animation(forKey: loop.key) != nil }.count
    }

    /// Adds `loop` to `layer` so that its phase now is the shared clock's: a loop that starts late,
    /// or again after its view was hidden, sits where one running all along would. The loop's own
    /// `timeOffset` (a star's or a row's offset from its neighbors) stays on top.
    /// - Parameters:
    ///   - loop: An infinite loop.
    ///   - layer: The layer it animates.
    ///   - key: The animation key.
    ///   - clock: The shared phase clock.
    public static func add(_ loop: CAAnimation, to layer: CALayer, forKey key: String, clock: SpinnerClock) {
        let cycle = loop.duration * (loop.autoreverses ? 2 : 1)
        loop.beginTime = layer.convertTime(clock.beginTime(cycle: cycle), from: nil)
        layer.add(loop, forKey: key)
    }

    private func start(_ layer: CALayer, key: String, make: Make) {
        guard let loop = make() else { return layer.removeAnimation(forKey: key) }
        Self.add(loop, to: layer, forKey: key, clock: clock)
    }

    /// Subscribes to ``node``'s flips while a loop is attached, and drops loops whose layer is gone.
    private func follow() {
        loops = loops.filter { $0.value.layer != nil }
        guard loops.isEmpty == (flips != nil) else { return }
        flips = loops.isEmpty ? nil : node.subscribe(owner: "LoopVisibility") { [weak self] visibility in self?.apply(visibility) }
    }

    private func apply(_ visibility: Visibility) {
        for loop in loops.values {
            guard let layer = loop.layer else { continue }
            if visibility.isVisible {
                start(layer, key: loop.key, make: loop.make)
            } else {
                layer.removeAnimation(forKey: loop.key)
            }
        }
        follow()
    }
}
