import AppKit
import CmuxNextDaemon
import CmuxNextLayout
import CmuxNextSettings

/// `debug.dock` (plans/cmux-next/dock-column.md): per window, the
/// active screen's docked columns, strip range and scrollbar in window
/// coordinates, plus whether the daemon serves `dock-columns-v1`, and a
/// top-level `docks` list (window, column, edge, mode, frame, rim), the
/// window's edge docks (`window_docks`) and whether any is drawn.
/// With `pane` and `dock` (bool, optional `edge`, `mode`) it first
/// changes that pane's column through the same path as every other entry
/// point (`ColumnDocking.apply`).
private typealias JSON = CmuxNextSettings.JSONValue

enum DebugDockColumns {
    static func handle(_ params: [String: CmuxNextSettings.JSONValue], services: AppServices) -> CmuxNextSettings.JSONValue {
        var error: String?
        if let key = params["pane"]?.stringValue, let flag = params["dock"]?.boolValue {
            error = set(key: key, dock: flag, params: params, services: services)
        }
        var docks: [JSON] = [], windowDocks: [JSON] = []
        let windows = services.windows.controllers.map { controller -> JSON in
            var fields: [String: JSON] = ["window": .string(controller.state.id)]
            windowDocks += controller.state.docks.debugRows(window: controller.state.id).compactMap(JSON.init(foundation:))
            if let report = controller.content?.layoutView.dockReport {
                fields["screen"] = encode(report)
                docks += report.debugColumns(window: controller.state.id).compactMap(JSON.init(foundation:))
            }
            return .object(fields)
        }
        var result: [String: JSON] = [
            "supported": .bool(services.activeDaemon.supports(DaemonCapability.dockColumns.rawValue)),
            "windows": .array(windows),
            "docks": .array(docks),
            "window_docks": .array(windowDocks),
            "window_dock_shown": .bool(services.windows.controllers.contains { !$0.state.docks.visible.isEmpty }),
        ]
        if let error { result["error"] = .string(error) }
        return .object(result)
    }

    private static func set(key: String, dock flag: Bool, params: [String: JSON], services: AppServices) -> String? {
        for controller in services.windows.controllers {
            guard let content = controller.content, content.paneController(key: key) != nil,
                  let column = content.layoutModel.dockColumn(containing: CmuxNextLayout.PaneID(key)) else { continue }
            let edge = params["edge"]?.stringValue.flatMap(DockEdge.init(rawValue:)) ?? column.dock?.edge ?? ColumnDocking.defaultEdge
            let mode = params["mode"]?.stringValue.flatMap(DockMode.init(rawValue:)) ?? column.dock?.mode ?? ColumnDocking.defaultMode
            do {
                try ColumnDocking.apply(flag ? DockColumn(edge: edge, mode: mode) : nil, to: column, in: content)
                return nil
            } catch {
                return String(describing: error)
            }
        }
        return "no column holds pane \(key)"
    }

    private static func encode(_ report: DockLayoutReport) -> JSON {
        .object([
            "dock": .array(report.columns.map { column in
                .object([
                    "column": .string(column.column.rawValue),
                    "edge": .string(column.dock.edge.rawValue),
                    "mode": .string(column.dock.mode.rawValue),
                    "frame_in_window": rect(column.frameInWindow),
                    "cover_in_window": rect(column.coverInWindow),
                    "rim_in_window": column.rimInWindow.map(rect) ?? .null,
                    "shown": .bool(column.shownAsDock),
                    "panes": .array(column.panes.map { .string($0.rawValue) }),
                    "glass_backdrop": .bool(column.hasBackdrop),
                ])
            }),
            "strip": .object([
                "min_x": .number(report.stripMinX), "width": .number(report.stripWidth),
                "uncovered_in_window": rect(report.uncoveredInWindow), "offset": .number(report.offset),
                "max_offset": .number(report.maxOffset), "content_width": .number(report.contentWidth),
            ]),
            "scrollbar": .object([
                "mode": .string(report.scrollbarMode.rawValue), "shown": .bool(report.scrollbarShown),
                "thumb_in_window": report.thumbInWindow.map(rect) ?? .null,
                "band_in_window": report.bandInWindow.map(rect) ?? .null,
            ]),
            "pane_stacking": .array(report.paneOrder.map { .string($0.rawValue) }),
        ])
    }

    private static func rect(_ rect: CGRect) -> JSON {
        .object(["x": .number(rect.minX), "y": .number(rect.minY), "width": .number(rect.width), "height": .number(rect.height)])
    }
}
