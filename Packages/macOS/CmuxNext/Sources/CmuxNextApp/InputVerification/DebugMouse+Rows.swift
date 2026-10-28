#if DEBUG || CMUX_BENCH_HOOKS
import AppKit
import CmuxNextBridge
import CmuxNextSettings

/// `debug.mouse` points named by what is under them, so a tour can drag a sidebar row onto the shown workspace on any
/// runner's window size (`scripts/cmux-next/media/tours/multi-view.json`): `row` (a workspace's name or id) is the
/// center of its sidebar row; a `drag`'s `to_edge` (`left`, `right`, `top`, `bottom`) is 10% in from that edge of the
/// shown workspace's content, where a row dropped with `sidebar.multiView` goes beside it.
extension DebugMouse {
    /// The center of the sidebar row of the workspace named or keyed `name` (top-left window-local points).
    static func rowPoint(_ name: String, controller: WindowController, window: NSWindow) -> NSPoint? {
        let services = controller.services
        let members = services.windows.registry.members(of: controller.state.id)
        guard let id = members.first(where: { $0 == name }) ?? members.first(where: { services.workspace(id: $0)?.name == name }) else { return nil }
        guard let screen = controller.sidebar.container.sidebarView.rowFrameOnScreen(for: SidebarWorkspaceID(id)) else { return nil }
        let center = window.convertPoint(fromScreen: NSPoint(x: screen.midX, y: screen.midY))
        return InputJournal.topLeftPoint(center, in: window, relativeTo: window)
    }

    /// Where a `drag` ends: `to_x`,`to_y`, or 10% in from the shown workspace's `to_edge`; else where it started.
    static func dragTarget(_ params: [String: JSONValue], from point: NSPoint, controller: WindowController, window: NSWindow) -> NSPoint {
        if let x = params["to_x"]?.doubleValue, let y = params["to_y"]?.doubleValue { return NSPoint(x: x, y: y) }
        guard let edge = params["to_edge"]?.stringValue, let view = controller.content?.contentView else { return point }
        let r = view.convert(view.bounds, to: nil) // window coordinates, y up
        let (dx, dy) = (r.width * 0.1, r.height * 0.1)
        let at: NSPoint? = switch edge {
        case "left": NSPoint(x: r.minX + dx, y: r.midY)
        case "right": NSPoint(x: r.maxX - dx, y: r.midY)
        case "top": NSPoint(x: r.midX, y: r.maxY - dy)
        case "bottom": NSPoint(x: r.midX, y: r.minY + dy)
        default: nil
        }
        return at.map { InputJournal.topLeftPoint($0, in: window, relativeTo: window) } ?? point
    }
}
#endif
