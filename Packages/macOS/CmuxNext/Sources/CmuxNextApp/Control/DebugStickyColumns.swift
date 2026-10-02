import AppKit
import CmuxNextDaemon
import CmuxNextLayout
import CmuxNextSettings

/// `debug.sticky` (plans/cmux-next/sticky-column.md): per window, the
/// active screen's sticky columns, strip range and scrollbar in window
/// coordinates, plus whether the daemon serves `sticky-columns-v1`.
/// With `pane` and `sticky` (bool, optional `edge`, `mode`) it first
/// changes that pane's column through the same path as every other entry
/// point (`StickyColumnHandlers.apply`).
private typealias JSON = CmuxNextSettings.JSONValue

enum DebugStickyColumns {
    static func handle(_ params: [String: CmuxNextSettings.JSONValue], services: AppServices) -> CmuxNextSettings.JSONValue {
        var error: String?
        if let key = params["pane"]?.stringValue, let flag = params["sticky"]?.boolValue {
            error = set(key: key, sticky: flag, params: params, services: services)
        }
        let windows = services.windows.controllers.map { controller -> JSON in
            var fields: [String: JSON] = ["window": .string(controller.state.id)]
            if let report = controller.content?.layoutView.stickyReport { fields["screen"] = encode(report) }
            return .object(fields)
        }
        var result: [String: JSON] = [
            "supported": .bool(services.activeDaemon.supports(DaemonCapabilities.shared.stickyColumns)),
            "windows": .array(windows),
        ]
        if let error { result["error"] = .string(error) }
        return .object(result)
    }

    private static func set(key: String, sticky flag: Bool, params: [String: JSON], services: AppServices) -> String? {
        for controller in services.windows.controllers {
            guard let content = controller.content, content.paneController(key: key) != nil,
                  let column = content.layoutModel.stickyColumn(containing: CmuxNextLayout.PaneID(key)) else { continue }
            let edge = params["edge"]?.stringValue.flatMap(StickyEdge.init(rawValue:)) ?? column.sticky?.edge ?? .right
            let mode = params["mode"]?.stringValue.flatMap(StickyMode.init(rawValue:)) ?? column.sticky?.mode ?? .docked
            do {
                try StickyColumnHandlers.apply(flag ? StickyColumn(edge: edge, mode: mode) : nil, to: column, in: content)
                return nil
            } catch {
                return String(describing: error)
            }
        }
        return "no column holds pane \(key)"
    }

    private static func encode(_ report: StickyLayoutReport) -> JSON {
        .object([
            "sticky": .array(report.columns.map { column in
                .object([
                    "column": .string(column.column.rawValue),
                    "edge": .string(column.sticky.edge.rawValue),
                    "mode": .string(column.sticky.mode.rawValue),
                    "frame_in_window": rect(column.frameInWindow),
                    "cover_in_window": rect(column.coverInWindow),
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
