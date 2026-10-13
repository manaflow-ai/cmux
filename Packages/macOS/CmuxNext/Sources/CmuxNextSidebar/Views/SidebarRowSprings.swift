import AppKit
import CmuxNextDesign
import QuartzCore

/// The sidebar's row and group-line motion on the window's one
/// `MotionClock` (DESIGN P3, P4; hq-1d): every row, opening row, closing
/// row and members' line of a change steps on the same `move` spring, from
/// where it shows now and with the velocity it has, so a retarget never
/// jumps and no row overlaps another in any frame.
///
/// A row view keeps its final size from the first frame (it lays out once);
/// each frame moves only its origin, and an opening or closing row shows
/// the springing part of its height through a mask on its layer. A members'
/// line is a plain bar, so its whole frame springs. The animator goes idle
/// when the last spring rests, so a sidebar at rest has no display link.
@MainActor
final class SidebarRowSprings: MotionAnimating {
    private struct Entry {
        weak var view: NSView?
        /// x, y: the origin; height: the visible height (rows) or the frame
        /// height (lines); width: the line width (rows keep `size.width`).
        var frame: AnimatedFrame
        /// A row's laid-out size; nil for a line, whose frame springs whole.
        var size: NSSize?
        var done: (@MainActor () -> Void)?
    }

    private weak var list: NSView?
    private var entries: [ObjectIdentifier: Entry] = [:]
    private weak var clock: MotionClock?
    /// Runs once every spring rests (the old block completion).
    private var settled: [@MainActor () -> Void] = []

    init(list: NSView) {
        self.list = list
    }

    /// True while `view` springs.
    func isMoving(_ view: NSView) -> Bool { entries[ObjectIdentifier(view)] != nil }

    /// The rect `view` shows now: its origin and its visible height.
    func presented(_ view: NSView) -> NSRect {
        guard let entry = entries[ObjectIdentifier(view)] else { return view.frame }
        return entry.size == nil ? entry.frame.rect
            : NSRect(x: entry.frame.x.value, y: entry.frame.y.value, width: view.frame.width, height: entry.frame.height.value)
    }

    /// Springs row `view` from what it shows (`start`, else its presented
    /// rect) to `target`, at its final size `target.size` from now on, with
    /// the visible height going from `start.height` to `visible`
    /// (`target.height` for a row that stays, 0 for one that closes).
    func row(_ view: NSView, from start: NSRect? = nil, to target: NSRect, visible: CGFloat? = nil,
             done: (@MainActor () -> Void)? = nil) {
        let id = ObjectIdentifier(view)
        var entry = entries[id] ?? Entry(view: view, frame: AnimatedFrame(start ?? presented(view)), size: target.size)
        if let start, entries[id] != nil {
            entry.frame.x.value = start.minX
            entry.frame.y.value = start.minY
            entry.frame.height.value = start.height
        }
        entry.size = target.size
        entry.frame.setTarget(NSRect(x: target.minX, y: target.minY, width: target.width, height: visible ?? target.height))
        entry.frame.width.snap(to: target.width)
        entry.done = done
        entries[id] = entry
        apply(entry)
    }

    /// Springs line `view` (its whole frame and opacity) to `target`.
    func line(_ view: NSView, to target: NSRect, alpha: CGFloat, done: (@MainActor () -> Void)? = nil) {
        let id = ObjectIdentifier(view)
        var entry = entries[id] ?? Entry(view: view, frame: AnimatedFrame(view.frame, alpha: view.alphaValue), size: nil)
        entry.frame.setTarget(target, alpha: alpha)
        entry.done = done
        entries[id] = entry
        apply(entry)
    }

    /// `view` stops springing where it is told to be next (a snap, a reuse).
    func cancel(_ view: NSView) {
        guard let entry = entries.removeValue(forKey: ObjectIdentifier(view)) else { return }
        if entry.size != nil { view.layer?.mask = nil }
    }

    /// Rows and lines and their targets move by `dy` at once (the viewport
    /// anchor step moves the offset with them).
    func shift(by dy: CGFloat) {
        for id in Array(entries.keys) {
            entries[id]?.frame.y.value += dy
            entries[id]?.frame.y.target += dy
        }
    }

    /// Runs `completion` once every spring rests (now, when none moves).
    func whenSettled(_ completion: @escaping @MainActor () -> Void) {
        settled.append(completion)
    }

    /// Starts stepping (call after the springs of one change are set).
    func start() {
        guard let list, list.window != nil, !entries.isEmpty else {
            // Off screen: nothing to show the motion on; every spring lands now.
            for id in Array(entries.keys) {
                guard var entry = entries.removeValue(forKey: id) else { continue }
                entry.frame.snap()
                apply(entry)
                if entry.size != nil { entry.view?.layer?.mask = nil }
                entry.done?()
            }
            return finish()
        }
        let target = MotionClock.forView(list)
        if let clock, clock !== target { clock.stop(self) }
        clock = target
        target.run(self, trace: "sidebar")
    }

    func motionStep(_ dt: Double) -> Bool {
        let parameters = Motion.spring(.move)
        for id in Array(entries.keys) {
            guard var entry = entries[id], let view = entry.view else {
                entries[id] = nil
                continue
            }
            let moving = entry.frame.advance(dt, parameters: parameters)
            entries[id] = entry
            apply(entry)
            guard !moving else { continue }
            entries[id] = nil
            if entry.size != nil { view.layer?.mask = nil }
            entry.done?()
        }
        if entries.isEmpty { finish() }
        return !entries.isEmpty
    }

    private func finish() {
        let pending = settled
        settled.removeAll()
        pending.forEach { $0() }
    }

    /// Places `entry`'s view: origin (and a line's size and opacity), and a
    /// row's mask while part of it is hidden.
    private func apply(_ entry: Entry) {
        guard let view = entry.view else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard let size = entry.size else {
            let rect = entry.frame.rect
            if view.frame != rect { view.frame = rect }
            view.alphaValue = entry.frame.alpha.value
            return
        }
        if view.frame.size != size { view.setFrameSize(size) }
        let origin = NSPoint(x: entry.frame.x.value, y: entry.frame.y.value)
        if view.frame.origin != origin { view.setFrameOrigin(origin) }
        guard let layer = view.layer else { return }
        let shown = min(max(entry.frame.height.value, 0), size.height)
        guard shown < size.height - 0.25 else {
            layer.mask = nil
            return
        }
        let mask = layer.mask ?? CALayer()
        mask.backgroundColor = NSColor.black.cgColor
        // The top `shown` points: y down when the layer draws flipped (a flipped row view).
        let top = layer.contentsAreFlipped() ? 0 : layer.bounds.height - shown
        mask.frame = CGRect(x: 0, y: top, width: layer.bounds.width, height: shown)
        if layer.mask !== mask { layer.mask = mask }
    }
}
