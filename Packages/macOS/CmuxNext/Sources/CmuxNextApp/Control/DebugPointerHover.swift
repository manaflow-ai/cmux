#if DEBUG || CMUX_BENCH_HOOKS
import AppKit
import CmuxNextDesign
import CmuxNextSettings
import CmuxNextSidebar

/// `debug.pointer_hover` {point: [x, y] | null, window?}: moves a synthetic
/// pointer (`SyntheticPointer`) to `point` (window coordinates, bottom-left
/// origin) in the window numbered `window` (default: the active main window)
/// and delivers real tracking-area enter / move / exit events there, so any
/// hover-driven view reacts as it would to the real pointer (a headless host
/// cannot hover any other way). `point` null (or absent) exits every area the
/// synthetic pointer is in. `row: <workspace id>` instead aims at the middle
/// of that sidebar row as drawn now (`identifier: <accessibility id>`: that control's). Returns the owners entered, exited and
/// still inside (their class names) and `row_hovered`, the workspace whose
/// row the sidebar shows hovered after the move. Debug builds only (cx-tupd).
@MainActor
enum DebugPointerHover {
    static func run(_ params: [String: JSONValue], services: AppServices) -> JSONValue {
        let window: NSWindow?
        if let number = params["window"]?.intValue ?? params["window"]?.stringValue.flatMap({ Int($0) }) {
            window = NSApp.windows.first { $0.windowNumber == number }
        } else {
            window = (services.windows.active ?? services.windows.controllers.first)?.window
        }
        guard let window, window.contentView != nil else { return .object(["error": .string("no window")]) }
        let sidebar = services.windows.controllers.first { $0.window === window }?.sidebar.container.sidebarView, rowID = params["row"]?.stringValue
        let coords = params["point"]?.arrayValue?.compactMap(\.doubleValue), row = rowID.flatMap { sidebar?.debugRowCenterInWindow(workspace: $0) }
        if let rowID, row == nil { return JSONValue(foundation: ["error": "the row is not drawn", "why": sidebar?.debugRowMiss(workspace: rowID) ?? ["controller": "none"]] as [String: Any]) ?? .null }
        let given = coords.flatMap { $0.count == 2 ? CGPoint(x: $0[0], y: $0[1]) : nil } ?? row ?? params["identifier"]?.stringValue.flatMap(window.debugCenter(ofAccessibilityIdentifier:)) ?? railPoint(params, in: window, services: services)
        guard given == nil, let badge = usageWarningPoint(params, in: window, services: services) else {
            return move(to: given, in: window, sidebar: sidebar)
        }
        // Hovering a row moves its warning badge left of the row's hover controls: hover it, let the
        // row lay out, then aim at where the badge is now, so the pointer rests on it (its tooltip).
        let first = move(to: badge, in: window, sidebar: nil)
        window.contentView?.layoutSubtreeIfNeeded()
        guard let settled = usageWarningPoint(params, in: window, services: services), settled != badge else { return first }
        return move(to: settled, in: window, sidebar: nil)
    }

    /// Moves the synthetic pointer to `point` (nil: out of every area) and delivers the events.
    private static func move(to point: CGPoint?, in window: NSWindow, sidebar: SidebarView?) -> JSONValue {
        let move = SyntheticPointer(window: window).move(to: point)
        func names(_ list: [String]) -> JSONValue { .array(list.map(JSONValue.string)) }
        return .object(["window": .number(Double(window.windowNumber)), "entered": names(move.entered), "exited": names(move.exited),
                        "inside": names(move.inside), "moved": .number(Double(move.moved)),
                        "row_hovered": sidebar?.debugHoveredWorkspace.map(JSONValue.string) ?? .null])
    }

    /// `debug.pointer_sweep {path: [workspace id], hz?}`: the synthetic pointer crosses the active main window's
    /// sidebar rows of `path` in order, `hz` moves a second (default 120), each move in its own main-actor turn
    /// paced by the clock, then leaves (`SyntheticPointer.sweep`). Returns each move's main-thread ms, the moves
    /// that were late or found no drawn row, and how many left their row hovered.
    static func sweep(_ params: [String: JSONValue], services: AppServices) async -> JSONValue {
        let path = params["path"]?.arrayValue?.compactMap(\.stringValue) ?? []
        guard let controller = services.windows.active ?? services.windows.controllers.first, let window = controller.window,
              !path.isEmpty else { return .object(["error": .string("no main window or no path")]) }
        let sidebar = controller.sidebar.container.sidebarView
        let result = await SyntheticPointer(window: window).sweep(count: path.count, hz: params["hz"]?.doubleValue ?? 120,
                                                                  target: { sidebar.debugRowCenterInWindow(workspace: path[$0]) },
                                                                  landed: { sidebar.debugHoveredWorkspace?.hasSuffix(path[$0]) == true })
        return JSONValue(foundation: result.foundation) ?? .null
    }
}
#endif
