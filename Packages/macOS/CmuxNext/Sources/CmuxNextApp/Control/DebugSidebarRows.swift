import AppKit
import CmuxNextDesign
import CmuxNextSettings
import CmuxNextSidebar

/// `debug.sidebar_rows`: each window's workspace-list rows with their
/// views (frame, alpha, in the list, the group it lists in), the selection and the dragged keys,
/// so a live drag can be checked row by row (R77, nxdog30), and the layout
/// items (Home, App Store, Settings) and the + button with their frames, so a proof clicks them.
/// `menu_x`, `menu_y` (window points from the top-left, as `debug.mouse`) add
/// the first window's `menu`: the titles a right-click there opens, built by
/// the list's own `menu(for:)` without showing it, and `submenus`: each
/// folder's titles by the folder's title.
enum DebugSidebarRows {
    static func report(_ params: [String: JSONValue] = [:], services: AppServices) -> JSONValue {
        if params["refuse_next_close"] == .bool(true) { ClosingWorkspaces.shared.refusesNext = true; return .object(["refuse_next_close": .bool(true)]) }
        if let motion = params["motion"]?.stringValue {
            return services.windows.controllers.first.map { json($0.sidebar.container.sidebarView.debugMotionReport(start: motion == "start")) } ?? .null
        }
        guard let x = params["menu_x"]?.doubleValue, let y = params["menu_y"]?.doubleValue else { return rows(services: services) }
        let menu = services.windows.controllers.first.flatMap {
            $0.sidebar.container.debugMenu(atWindowPoint: CGPoint(x: x, y: y))
        }
        func titles(_ menu: NSMenu) -> JSONValue { .array(menu.items.map { .string($0.isSeparatorItem ? "-" : $0.title) }) }
        let submenus = (menu?.items ?? []).compactMap { item in item.submenu.map { (item.title, titles($0)) } }
        return .object(["menu": menu.map(titles) ?? .null,
                        "submenus": .object(Dictionary(submenus, uniquingKeysWith: { first, _ in first }))])
    }

    private static func rows(services: AppServices) -> JSONValue {
        // `doc`: the sidebar document path is on, and the mirror's FFI calls so far (two per drag: drag_begin, the drop).
        .object(["open_tab_favicons": .object(services.openTabFaviconsByOrigin().mapValues(JSONValue.string)), "doc": .object(["active": .bool(services.sidebarDoc.store?.isActive == true), "ffi_calls": .object(SidebarMirror.calls.mapValues { .number(Double($0)) })]),
                 "windows": .array(services.windows.controllers.map { controller in
            var window = controller.sidebar.container.sidebarView.debugReport()
            window["window"] = controller.state.id
            return json(window)
        })])
    }

    /// The window's sidebar layout items (debug.sidebar_rows "items").
    static func items(of controller: WindowController) -> [JSONValue] {
        controller.sidebar.container.sidebarView.debugLayoutItemsReport().map(json)
    }

    /// The sidebar's JSONSerialization graph (SidebarView+DebugReport) as JSON.
    private static func json(_ object: Any) -> JSONValue { JSONValue(foundation: object) ?? .null }
}
