import AppKit
import CmuxNextDesign
import CmuxNextSettings
import CmuxNextSidebar

/// `debug.sidebar_rows`: each window's workspace-list rows with their
/// views (frame, alpha, in the list), the selection and the dragged keys,
/// so a live drag can be checked row by row (R77, nxdog30).
enum DebugSidebarRows {
    static func report(services: AppServices) -> JSONValue {
        .object(["windows": .array(services.windows.controllers.map { controller in
            let sidebar = controller.sidebar.container.sidebarView
            let (rows, selection, dragging) = sidebar.debugRows()
            return .object([
                "window": .string(controller.state.id),
                "selection": .array(selection.map(JSONValue.string)),
                "dragging": .array(dragging.map(JSONValue.string)),
                "paging": .object(sidebar.debugPaging().mapValues(JSONValue.string)),
                "rows": .array(rows.map { row in
                    .object([
                        "key": .string(row.key), "title": row.title.map(JSONValue.string) ?? .null,
                        "frame": rect(row.frame), "window_frame": rect(row.windowFrame), "view_frame": row.viewFrame.map(rect) ?? .null,
                        "view_alpha": row.viewAlpha.map { .number(Double($0)) } ?? .null,
                        "in_list": .bool(row.inList), "suppressed": .bool(row.suppressed),
                    ])
                }),
            ])
        })])
    }

    /// The window's sidebar layout items (debug.sidebar_rows "items").
    static func items(of controller: WindowController) -> [JSONValue] {
        []
    }

    private static func rect(_ r: CGRect) -> JSONValue {
        .object(["x": .number(r.minX), "y": .number(r.minY), "width": .number(r.width), "height": .number(r.height)])
    }
}
