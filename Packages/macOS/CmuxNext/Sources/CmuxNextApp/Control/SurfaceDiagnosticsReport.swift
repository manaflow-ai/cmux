import AppKit
import CmuxNextSettings

/// `debug.surfaces`: every window's panes with their surface state, the
/// blank-pane count, and the content cache's live counts. Main actor: it
/// reads AppKit views. Creates nothing.
@MainActor
enum SurfaceDiagnosticsReport {
    static func statuses(_ services: AppServices) -> [(window: WindowController, pane: PaneController, status: PaneSurfaceStatus)] {
        var result: [(WindowController, PaneController, PaneSurfaceStatus)] = []
        for controller in services.windows.controllers {
            guard let content = controller.content else { continue }
            let panes = content.panes.values.sorted { $0.paneKey < $1.paneKey }
            for pane in panes { result.append((controller, pane, pane.surfaceStatus)) }
        }
        return result
    }

    static func make(_ services: AppServices) -> JSONValue {
        let rows = statuses(services)
        var windows: [String: [JSONValue]] = [:]
        var order: [String] = []
        for row in rows {
            let key = row.window.window.map { String($0.windowNumber) } ?? "none"
            if windows[key] == nil { order.append(key) }
            var pane = row.status.json
            if case .object(var object) = pane {
                object["workspace"] = .string(row.window.content?.workspace.id ?? "")
                object["focused"] = .bool(row.pane.isFocusedInWorkspace)
                if let tab = row.status.selectedTab { object["phase"] = .string(services.cache.phase(of: tab).rawValue) }
                pane = .object(object)
            }
            windows[key, default: []].append(pane)
        }
        let blank = rows.filter(\.status.isBlank).count
        return [
            "windows": .array(order.map { key in ["window": .string(key), "panes": .array(windows[key] ?? [])] }),
            "blank_panes": JSONValue(blank),
            "collapsed_panes": JSONValue(rows.filter(\.status.isCollapsed).count),
            "keep_alive_panes": JSONValue(rows.filter { $0.status.presence == "keep_alive" }.count),
            "cold_keep_alive_panes": JSONValue(rows.filter(\.status.isColdKeepAlive).count),
            "live_terminals": JSONValue(services.cache.liveTerminalCount),
            "invariant_violations": JSONValue(services.surfaceInvariant.violations),
            "invariant_checks": JSONValue(services.surfaceInvariant.checks),
            "warm_terminal_capacity": JSONValue(services.cache.warmBudget.terminalCapacity),
            "parked_workspaces": JSONValue(services.windows.controllers.reduce(0) { $0 + $1.parked.count }),
            "hibernation": hibernation(services),
        ]
    }

    private static func hibernation(_ services: AppServices) -> JSONValue {
        guard let hibernation = services.cache.hibernation else { return .null }
        let setting = hibernation.setting
        return [
            "mode": setting.configValue.stringValue.map(JSONValue.string) ?? .number(setting.hiddenMinutes ?? 0),
            "pressure": .string(hibernation.pressure.rawValue),
            "hibernated": .array(services.cache.dormantTabs.ids.sorted().map(JSONValue.string)),
            "hibernated_total": JSONValue(hibernation.hibernatedCount),
            "restored_total": JSONValue(hibernation.restoredCount),
            "exemptions": .object(hibernation.exemptions.mapValues { .string($0.rawValue) }),
        ]
    }
}
