import CmuxNextPages
import AppKit
import CmuxNextSettings
import CmuxNextTerminal

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

    /// `includeText` adds each terminal mirror's viewport text (`text`), so a
    /// script can check that a view renders what its daemon terminal shows.
    static func make(_ services: AppServices, includeText: Bool = false) -> JSONValue {
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
                // A web page tab has no terminal lifecycle: report its paint state, not `restoring`.
                if case .page(let view)? = row.pane.currentTabKey.flatMap(row.pane.existingContent(for:)),
                   let page = view.content as? PageWebView {
                    object["phase"] = .string(page.hasPainted ? "painted" : "loading")
                }
                if case .terminal(let entry)? = row.pane.currentTabKey.flatMap(row.pane.existingContent(for:)) {
                    object["attach"] = .string(entry.io.attachPhase.journalName)
                    object["link"] = .string(Self.linkName(entry.session.model.connection))
                    let diagnostics = entry.session.diagnostics
                    object["snapshots"] = JSONValue(diagnostics.restoredSnapshots)
                    object["surface_swaps"] = JSONValue(diagnostics.swappedSurfaces)
                    object["local_history_mismatch"] = JSONValue(diagnostics.localHistoryMismatches)
                    object["local_snapshots"] = JSONValue(diagnostics.localSnapshots)
                    if includeText { object["text"] = entry.session.surfaceView.viewportText().map(JSONValue.string) ?? .null }
                }
                if case .placeholder(let view)? = row.pane.currentTabKey.flatMap(row.pane.existingContent(for:)) {
                    // A remote-terminal tab whose session is away (data-model.md 1.4).
                    object["placeholder"] = .string(view.statusText)
                    if includeText { object["text"] = .string(view.snapshotText) }
                }
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

    private static func linkName(_ status: TerminalConnectionStatus) -> String {
        switch status {
        case .connected: "connected"
        case .exited: "exited"
        case .disconnected(let cause, let reconnecting): "disconnected:\(cause)\(reconnecting ? ":reconnecting" : "")"
        }
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
