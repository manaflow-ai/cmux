import Foundation

struct CmuxTaskManagerSnapshot {
    static let empty = CmuxTaskManagerSnapshot(
        rows: [],
        total: .zero,
        sampledAt: nil
    )

    let rows: [CmuxTaskManagerRow]
    let total: CmuxTaskManagerResources
    let sampledAt: Date?

    var updatedText: String {
        guard let sampledAt else {
            return String(localized: "taskManager.updated.never", defaultValue: "Never")
        }
        return CmuxTaskManagerFormat.time(sampledAt)
    }

    init(rows: [CmuxTaskManagerRow], total: CmuxTaskManagerResources, sampledAt: Date?) {
        self.rows = rows
        self.total = total
        self.sampledAt = sampledAt
    }

    init(payload: [String: Any]) {
        let sample = payload["sample"] as? [String: Any] ?? [:]
        self.sampledAt = CmuxTaskManagerFormat.iso8601Date(sample["sampled_at"] as? String)
        self.total = CmuxTaskManagerResources(payload["totals"] as? [String: Any] ?? [:])

        var rows: [CmuxTaskManagerRow] = []
        let windows = payload["windows"] as? [[String: Any]] ?? []
        for window in windows {
            Self.appendWindow(window, to: &rows)
        }
        self.rows = rows
    }

    private static func appendWindow(_ window: [String: Any], to rows: inout [CmuxTaskManagerRow]) {
        let handle = displayHandle(window)
        var detailParts: [String] = []
        if bool(window["key"]) {
            detailParts.append(String(localized: "taskManager.row.keyWindow", defaultValue: "Key window"))
        }
        if bool(window["visible"]) == false {
            detailParts.append(String(localized: "taskManager.row.hidden", defaultValue: "Hidden"))
        }
        rows.append(row(
            window,
            kind: .window,
            level: 0,
            title: String(localized: "taskManager.row.window", defaultValue: "Window \(handle)"),
            detail: detailParts.joined(separator: " / ")
        ))

        let workspaces = window["workspaces"] as? [[String: Any]] ?? []
        for workspace in workspaces {
            appendWorkspace(workspace, to: &rows)
        }
    }

    private static func appendWorkspace(_ workspace: [String: Any], to rows: inout [CmuxTaskManagerRow]) {
        let title = nonEmptyString(workspace["title"]) ?? displayHandle(workspace)
        var detailParts: [String] = []
        if bool(workspace["selected"]) {
            detailParts.append(String(localized: "taskManager.row.selected", defaultValue: "Selected"))
        }
        if bool(workspace["pinned"]) {
            detailParts.append(String(localized: "taskManager.row.pinned", defaultValue: "Pinned"))
        }
        rows.append(row(
            workspace,
            kind: .workspace,
            level: 1,
            title: title,
            detail: detailParts.joined(separator: " / ")
        ))

        let tags = workspace["tags"] as? [[String: Any]] ?? []
        for tag in tags {
            appendTag(tag, to: &rows)
        }

        let panes = workspace["panes"] as? [[String: Any]] ?? []
        for pane in panes {
            appendPane(pane, to: &rows)
        }
    }

    private static func appendTag(_ tag: [String: Any], to rows: inout [CmuxTaskManagerRow]) {
        let key = nonEmptyString(tag["key"]) ?? String(localized: "taskManager.row.unknownTag", defaultValue: "Unknown tag")
        let value = nonEmptyString(tag["value"])
        let title = value.map { "\(key): \($0)" } ?? key
        let detail = int(tag["pid"]).map {
            String(localized: "taskManager.row.pid", defaultValue: "PID \($0)")
        } ?? ""
        rows.append(row(tag, kind: .tag, level: 2, title: title, detail: detail, isDimmed: bool(tag["visible"]) == false))

        let processes = tag["processes"] as? [[String: Any]] ?? []
        let context = rowID(tag, kind: .tag)
        for process in processes {
            appendProcess(process, level: 3, context: context, to: &rows)
        }
    }

    private static func appendPane(_ pane: [String: Any], to rows: inout [CmuxTaskManagerRow]) {
        let handle = displayHandle(pane)
        rows.append(row(
            pane,
            kind: .pane,
            level: 2,
            title: String(localized: "taskManager.row.pane", defaultValue: "Pane \(handle)"),
            detail: bool(pane["focused"]) ? String(localized: "taskManager.row.focused", defaultValue: "Focused") : ""
        ))

        let surfaces = pane["surfaces"] as? [[String: Any]] ?? []
        for surface in surfaces {
            appendSurface(surface, to: &rows)
        }
    }

    private static func appendSurface(_ surface: [String: Any], to rows: inout [CmuxTaskManagerRow]) {
        let type = (nonEmptyString(surface["type"]) ?? "unknown").lowercased()
        let title = nonEmptyString(surface["title"]) ?? displayHandle(surface)
        var detailParts = [surfaceTypeLabel(type)]
        if bool(surface["selected"]) {
            detailParts.append(String(localized: "taskManager.row.selected", defaultValue: "Selected"))
        }
        if let tty = nonEmptyString(surface["tty"]) {
            detailParts.append(tty)
        }
        if let url = nonEmptyString(surface["url"]) {
            detailParts.append(url)
        }
        rows.append(row(
            surface,
            kind: type == "browser" ? .browserSurface : .terminalSurface,
            level: 3,
            title: title,
            detail: detailParts.joined(separator: " / ")
        ))

        let webviews = surface["webviews"] as? [[String: Any]] ?? []
        if !webviews.isEmpty {
            for webview in webviews {
                appendWebView(webview, to: &rows)
            }
        }
        let processes = surface["processes"] as? [[String: Any]] ?? []
        let context = rowID(surface, kind: type == "browser" ? .browserSurface : .terminalSurface)
        for process in processes {
            appendProcess(process, level: 4, context: context, to: &rows)
        }
    }

    private static func appendWebView(_ webview: [String: Any], to rows: inout [CmuxTaskManagerRow]) {
        let title = nonEmptyString(webview["title"])
            ?? String(localized: "taskManager.row.webview", defaultValue: "WebView")
        var detailParts: [String] = []
        if let pid = int(webview["pid"]) {
            detailParts.append(String(localized: "taskManager.row.pid", defaultValue: "PID \(pid)"))
        }
        if let sharedCount = int(webview["shared_process_count"]), sharedCount > 1 {
            detailParts.append(String(localized: "taskManager.row.sharedProcess", defaultValue: "Shared x\(sharedCount)"))
        }
        if let url = nonEmptyString(webview["url"]) {
            detailParts.append(url)
        }
        rows.append(row(webview, kind: .webview, level: 4, title: title, detail: detailParts.joined(separator: " / ")))

        let processes = webview["processes"] as? [[String: Any]] ?? []
        let context = rowID(webview, kind: .webview)
        for process in processes {
            appendProcess(process, level: 5, context: context, to: &rows)
        }
    }

    private static func appendProcess(
        _ process: [String: Any],
        level: Int,
        context: String,
        to rows: inout [CmuxTaskManagerRow]
    ) {
        let pid = int(process["pid"])
        let title = nonEmptyString(process["name"])
            ?? pid.map { String(localized: "taskManager.row.processWithPID", defaultValue: "Process \($0)") }
            ?? String(localized: "taskManager.row.process", defaultValue: "Process")
        let detail = pid.map {
            String(localized: "taskManager.row.pid", defaultValue: "PID \($0)")
        } ?? ""
        let processRow = row(process, kind: .process, level: level, title: title, detail: detail, context: context)
        rows.append(processRow)

        let children = process["children"] as? [[String: Any]] ?? []
        for child in children {
            appendProcess(child, level: level + 1, context: processRow.id, to: &rows)
        }
    }

    private static func row(
        _ payload: [String: Any],
        kind: CmuxTaskManagerRow.Kind,
        level: Int,
        title: String,
        detail: String,
        isDimmed: Bool = false,
        context: String? = nil
    ) -> CmuxTaskManagerRow {
        CmuxTaskManagerRow(
            id: rowID(payload, kind: kind, context: context),
            kind: kind,
            level: level,
            title: title,
            detail: detail,
            resources: CmuxTaskManagerResources(payload["resources"] as? [String: Any] ?? [:]),
            isDimmed: isDimmed
        )
    }

    private static func rowID(
        _ payload: [String: Any],
        kind: CmuxTaskManagerRow.Kind,
        context: String? = nil
    ) -> String {
        if kind == .process, let context {
            if let id = nonEmptyString(payload["id"]) {
                return "\(kind.rawValue):\(context):\(id)"
            }
            if let ref = nonEmptyString(payload["ref"]) {
                return "\(kind.rawValue):\(context):\(ref)"
            }
            if let pid = int(payload["pid"]) {
                return "\(kind.rawValue):\(context):pid:\(pid)"
            }
        }
        if let id = nonEmptyString(payload["id"]) {
            return "\(kind.rawValue):\(id)"
        }
        if let pid = int(payload["pid"]) {
            return "\(kind.rawValue):pid:\(pid)"
        }
        if let ref = nonEmptyString(payload["ref"]) {
            return "\(kind.rawValue):\(ref)"
        }
        return "\(kind.rawValue):\(UUID().uuidString)"
    }

    private static func displayHandle(_ payload: [String: Any]) -> String {
        nonEmptyString(payload["ref"]) ?? nonEmptyString(payload["id"]) ?? "?"
    }

    private static func surfaceTypeLabel(_ type: String) -> String {
        switch type {
        case "browser":
            return String(localized: "taskManager.row.surfaceType.browser", defaultValue: "Browser")
        case "terminal":
            return String(localized: "taskManager.row.surfaceType.terminal", defaultValue: "Terminal")
        case "unknown", "":
            return String(localized: "taskManager.row.surfaceType.unknown", defaultValue: "Unknown")
        default:
            return type
        }
    }

    private static func nonEmptyString(_ raw: Any?) -> String? {
        guard let value = raw as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func bool(_ raw: Any?) -> Bool {
        if let value = raw as? Bool { return value }
        if let value = raw as? NSNumber { return value.boolValue }
        return false
    }

    private static func int(_ raw: Any?) -> Int? {
        if let value = raw as? Int { return value }
        if let value = raw as? NSNumber { return value.intValue }
        if let value = raw as? String {
            return Int(value.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }
}
