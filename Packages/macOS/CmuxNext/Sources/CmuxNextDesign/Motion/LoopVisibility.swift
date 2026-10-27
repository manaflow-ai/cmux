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
/// A loop at an ambient rate (``FrameRate/isAmbient``, the default: a spinner, a twinkle, a sweep) is
/// also off its layer while the app's ``DisplayClock/power`` caps frames (Low Power Mode, a serious or
/// critical thermal state; feature `powerFrameCaps`), and is made again at its shared-clock phase when
/// the cap lifts, as for a node that shows again. A loop that follows the person (edit mode's wiggle)
/// attaches at ``FrameRate/motion`` and never pauses for power. Chrome's battery saver stops the same
/// decorative frames (components/performance_manager/user_tuning/battery_saver_mode_manager.cc).
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
    /// The clock whose ``DisplayClock/power`` pauses ambient loops, read when the first one attaches.
    private let displays: @MainActor () -> DisplayClock
    private var loops: [LoopKey: Loop] = [:]
    /// Held only while a loop is attached, so a view with no loop costs its node no subscriber.
    private var flips: VisibilitySubscription?
    /// The power changes of ``displays``: held only while an ambient loop is attached.
    private var powerWatch: PowerStateSubscription?
    /// ``isPowerPaused`` as the loops last applied it, so a power change that keeps it (a fair Mac
    /// getting warmer) touches no layer.
    private var appliedPowerPause = false

    private struct LoopKey: Hashable {
        let layer: ObjectIdentifier
        let key: String
    }

    private struct Loop {
        weak var layer: CALayer?
        let key: String
        let rate: FrameRate
        let make: Make
    }

    /// - Parameters:
    ///   - name: The node's name in diagnostics (`nightSky`, `sidebar.row.wiggle`).
    ///   - clock: The media-time clock a loop's phase is counted from; tests pass fixed times.
    ///   - displays: The display clock whose power state pauses ambient loops: the composition root's one
    ///     clock (``FrameScheduler/appDisplays``) by default; tests pass one whose power they set.
    public init(_ name: String, clock: SpinnerClock = SpinnerClock(),
                displays: @escaping @MainActor () -> DisplayClock = { FrameScheduler.appDisplays }) {
        view = ViewVisibility(name)
        self.clock = clock
        self.displays = displays
    }

    /// Puts ``node`` under `window`'s node, or under the hidden root for no window. The view calls it
    /// from `viewDidMoveToWindow`; its `viewDidHide` / `viewDidUnhide` set ``node`` hidden / visible
    /// (recipe R-hide, plans/cmux-next/chrome-parity/p06-scheduler.md).
    /// - Parameter window: The view's window.
    public func place(in window: NSWindow?) {
        view.place(in: window)
    }

    /// Runs `make`'s loop on `layer` under `key` whenever ``node`` is visible (and, at an ambient
    /// `rate`, the power state does not pause it), replacing any loop attached there before. Allowed
    /// now, the loop starts in this turn.
    /// - Parameters:
    ///   - layer: The layer the loop animates (held weakly).
    ///   - key: The animation key on `layer`.
    ///   - rate: The loop's frame-rate class: ambient (the default) pauses while the power state caps
    ///     frames; ``FrameRate/motion`` for a loop that follows the person.
    ///   - make: Makes the loop each time it starts, so it follows the motion settings of that moment.
    public func attach(_ layer: CALayer, key: String, rate: FrameRate = .ambient, make: @escaping Make) {
        let loop = Loop(layer: layer, key: key, rate: rate, make: make)
        loops[LoopKey(layer: ObjectIdentifier(layer), key: key)] = loop
        follow()
        layer.removeAnimation(forKey: key)
        if runs(loop) { start(layer, key: key, make: make) }
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

    /// Whether the power state keeps ambient loops off their layers now.
    public var isPowerPaused: Bool { power.pauses(.ambient) }

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

    /// The power state of ``displays`` while an ambient loop is attached; nominal otherwise.
    private var power: PowerState { powerWatch?.power ?? .nominal }

    /// Whether `loop` belongs on its layer now: its node is visible and the power state does not pause its rate.
    private func runs(_ loop: Loop) -> Bool { node.isVisible && !power.pauses(loop.rate) }

    /// Subscribes to ``node``'s flips while a loop is attached and to the power state while an ambient
    /// one is, and drops loops whose layer is gone.
    private func follow() {
        loops = loops.filter { $0.value.layer != nil }
        if loops.isEmpty != (flips == nil) {
            flips = loops.isEmpty ? nil : node.subscribe(owner: "LoopVisibility") { [weak self] _ in self?.apply(all: true) }
        }
        let wantsPower = loops.values.contains { $0.rate.isAmbient }
        if wantsPower != (powerWatch != nil) {
            powerWatch = wantsPower ? displays().subscribePower(owner: "LoopVisibility.\(node.name)") { [weak self] _ in self?.powerDidChange() } : nil
            appliedPowerPause = isPowerPaused
        }
    }

    /// The power state changed: the ambient loops come off when the cap starts and back when it lifts.
    private func powerDidChange() {
        guard isPowerPaused != appliedPowerPause else { return }
        appliedPowerPause = isPowerPaused
        apply(all: false)
    }

    /// Puts each loop on its layer or takes it off after a change: every loop on a visibility flip
    /// (`all`), only the ambient ones on a power change.
    private func apply(all: Bool) {
        for loop in loops.values where all || loop.rate.isAmbient {
            guard let layer = loop.layer else { continue }
            if runs(loop) {
                start(layer, key: loop.key, make: loop.make)
            } else {
                layer.removeAnimation(forKey: loop.key)
            }
        }
        follow()
    }
}
