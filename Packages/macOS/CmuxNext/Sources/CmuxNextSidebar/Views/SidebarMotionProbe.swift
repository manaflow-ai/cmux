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
    /// Main-thread milliseconds the list spent in its last drag update (0 when none).
    public var dragWorkMs: Double
}

/// Samples the list once per display frame while on. Off by default; one
/// frame client of the list's window, active only between start and stop.
@MainActor
final class SidebarMotionProbe {
    private unowned let list: SidebarListView
    private(set) var frames: [SidebarMotionFrame] = []
    static let capacity = 4000
    private lazy var client = FrameClient(owner: "Sidebar.motionProbe", view: list) { [weak self] tick in
        self?.sample(tick.timestamp) ?? false
    }

    init(list: SidebarListView) {
        self.list = list
    }

    func start() {
        frames.removeAll()
        client.activate()
    }

    func stop() -> [SidebarMotionFrame] {
        client.deactivate()
        defer { frames.removeAll() }
        return frames
    }

    private func sample(_ time: CFTimeInterval) -> Bool {
        guard frames.count < Self.capacity else { return false }
        var views: [String: CGRect] = [:]
        for (key, view) in list.rowViews {
            views[String(describing: key)] = Self.presented(view)
            guard let block = view as? SidebarBlockRowView else { continue }
            let origin = Self.presented(view).origin
            for (id, item) in block.region.itemViews where !id.isTransient {
                views["item:" + id.rawValue] = Self.presented(item).offsetBy(dx: origin.x, dy: origin.y)
            }
        }
        let lift = list.drag?.lift ?? list.settling?.drag.lift
        frames.append(SidebarMotionFrame(time: time, scrollY: list.enclosingScrollView?.contentView.bounds.minY ?? 0,
                                         lift: lift.map(Self.presented), views: views, dragWorkMs: list.lastDragWorkMs))
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
