#if DEBUG || CMUX_BENCH_HOOKS
public import CoreGraphics
import AppKit
import CmuxNextWakeups
import QuartzCore

/// One display frame of the sidebar as the render server shows it, for
/// `debug.sidebar_rows {"motion": "start"|"stop"}` (sidebar-v2 drag feel
/// proof): every realized list row's and block item's presented frame
/// (list coordinates), the lifted card's presented frame and the scroll
/// offset. A frame check finds a jump (a non-dragged view that moves more
/// than its spring can in one frame) and a gap that does not open
/// continuously, without pixel analysis.
public struct SidebarMotionFrame: Sendable {
    public var time: CFTimeInterval
    public var scrollY: CGFloat
    public var lift: CGRect?
    /// Row key (or `item:<id>` for a block item) -> presented frame.
    public var views: [String: CGRect]
    /// Presented opacity by the same keys (a hidden or fading view is not a pop).
    public var opacity: [String: Float]
    /// Main-thread milliseconds the list spent in its last drag update (0 when none).
    public var dragWorkMs: Double
    /// The list's model structure (`SidebarModel.sectionsRevision`): a change marks a drop's optimistic model or its echo.
    public var revision: UInt64
    /// A dropped drag still shows its look (`SidebarListView.settling`).
    public var settling: Bool
}

/// Samples the list once per display frame while on. Off by default; one
/// frame client of the list's window, active only between start and stop.
@MainActor
final class SidebarMotionProbe {
    private weak var list: SidebarListView?
    private(set) var frames: [SidebarMotionFrame] = []
    static let capacity = 4000
    private var client: FrameClient?
    init(list: SidebarListView) {
        self.list = list
        // Stamped when the presentation is read (`presented` evaluates the springs now), not at the display
        // link's last vsync: the main thread runs the tick late by a varying delay, and a vsync stamp turned a
        // spring's steady motion into false 8-11 pt "jumps" between late and early samples (ptr8 scenario 3).
        client = FrameClient(owner: "Sidebar.motionProbe", view: list) { [weak self] _ in self?.sample(CACurrentMediaTime()) ?? false }
    }

    func start() {
        frames.removeAll()
        client?.activate()
    }

    func stop() -> [SidebarMotionFrame] {
        client?.deactivate()
        defer { frames.removeAll() }
        return frames
    }

    private func sample(_ time: CFTimeInterval) -> Bool {
        guard let list, frames.count < Self.capacity else { return false }
        var views: [String: CGRect] = [:]
        var opacity: [String: Float] = [:]
        let fading = list.fadingRows.values.map { (key: $0.key, view: $0) }
        for (key, view) in fading + list.rowViews.map({ (key: $0.key, view: $0.value) }) { // a live row wins over a fading one
            views[String(describing: key)] = Self.presented(view)
            opacity[String(describing: key)] = view.layer?.presentation()?.opacity ?? Float(view.alphaValue)
            guard let block = view as? SidebarBlockRowView else { continue }
            let origin = Self.presented(view).origin
            for (id, item) in block.region.itemViews where !id.isTransient {
                views["item:" + id.rawValue] = Self.presented(item).offsetBy(dx: origin.x, dy: origin.y)
                opacity["item:" + id.rawValue] = item.layer?.presentation()?.opacity ?? Float(item.alphaValue)
            }
        }
        let lift = list.drag?.lift ?? list.settling?.drag.lift ?? list.landing.flatMap { $0.lift.superview == nil ? nil : $0.lift }
        frames.append(SidebarMotionFrame(time: time, scrollY: list.enclosingScrollView?.contentView.bounds.minY ?? 0,
                                         lift: lift.map(Self.presented), views: views, opacity: opacity, dragWorkMs: list.lastDragWorkMs,
                                         revision: list.model.sectionsRevision, settling: list.settling != nil))
        return true
    }

    /// The view's frame as the render server draws it now (mid-animation).
    private static func presented(_ view: NSView) -> CGRect {
        guard let layer = view.layer, let shown = layer.presentation() else { return view.frame }
        return CGRect(x: shown.position.x - shown.bounds.width * shown.anchorPoint.x,
                      y: shown.position.y - shown.bounds.height * shown.anchorPoint.y,
                      width: shown.bounds.width, height: shown.bounds.height)
    }
}
#endif
