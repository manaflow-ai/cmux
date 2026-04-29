import AppKit
import Combine
import SwiftUI

@MainActor
final class TaskManagerWindowController: NSWindowController, NSWindowDelegate {
    static let shared = TaskManagerWindowController()

    private let model = CmuxTaskManagerModel()

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 940, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier("cmux.taskManager")
        window.title = String(localized: "taskManager.windowTitle", defaultValue: "Task Manager")
        window.center()
        window.contentView = NSHostingView(rootView: CmuxTaskManagerView(model: model))
        AppDelegate.shared?.applyWindowDecorations(to: window)
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        guard let window else { return }
        if !window.isVisible {
            window.center()
        }
        model.start()
        NSApp.unhide(nil)
        window.makeKeyAndOrderFront(nil)
        NSRunningApplication.current.activate(options: [.activateAllWindows])
    }

    func windowWillClose(_ notification: Notification) {
        model.stop()
    }
}

@MainActor
private final class CmuxTaskManagerModel: ObservableObject {
    @Published private(set) var snapshot = CmuxTaskManagerSnapshot.empty
    @Published private(set) var isRefreshing = false
    @Published private(set) var errorMessage: String?
    @Published var includesProcesses = false {
        didSet {
            guard oldValue != includesProcesses else { return }
            refresh(force: true)
        }
    }

    private var refreshTimer: Timer?
    private var refreshTask: Task<Void, Never>?
    private let refreshInterval: TimeInterval = 3.0

    func start() {
        guard refreshTimer == nil else {
            refresh(force: true)
            return
        }
        refresh(force: true)
        let timer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refresh()
            }
        }
        timer.tolerance = 0.75
        refreshTimer = timer
    }

    func stop() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        refreshTask?.cancel()
        refreshTask = nil
        isRefreshing = false
    }

    func refresh(force: Bool = false) {
        if refreshTask != nil {
            guard force else { return }
            refreshTask?.cancel()
            refreshTask = nil
        }

        let includeProcesses = includesProcesses
        isRefreshing = true
        refreshTask = Task { [weak self] in
            do {
                let payload = try await TerminalController.shared.taskManagerTopPayload(includeProcesses: includeProcesses)
                guard !Task.isCancelled else { return }
                let snapshot = CmuxTaskManagerSnapshot(payload: payload)
                self?.snapshot = snapshot
                self?.errorMessage = nil
            } catch {
                guard !Task.isCancelled else { return }
                self?.errorMessage = String(describing: error)
            }
            self?.isRefreshing = false
            self?.refreshTask = nil
        }
    }
}

private struct CmuxTaskManagerView: View {
    @ObservedObject var model: CmuxTaskManagerModel

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            summary
            Divider()
            tableHeader
            Divider()
            tableBody
        }
        .frame(minWidth: 820, minHeight: 480)
        .onAppear {
            model.start()
        }
        .onDisappear {
            model.stop()
        }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Text(String(localized: "taskManager.title", defaultValue: "Task Manager"))
                .font(.title3.weight(.semibold))

            if model.isRefreshing {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(String(localized: "taskManager.refreshing", defaultValue: "Refreshing"))
            }

            Spacer()

            Toggle(
                String(localized: "taskManager.showProcesses", defaultValue: "Processes"),
                isOn: $model.includesProcesses
            )
            .toggleStyle(.checkbox)

            Button {
                model.refresh(force: true)
            } label: {
                Label(String(localized: "taskManager.refresh", defaultValue: "Refresh"), systemImage: "arrow.clockwise")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var summary: some View {
        HStack(spacing: 24) {
            metric(
                title: String(localized: "taskManager.summary.cpu", defaultValue: "CPU"),
                value: CmuxTaskManagerFormat.cpu(model.snapshot.total.cpuPercent)
            )
            metric(
                title: String(localized: "taskManager.summary.memory", defaultValue: "Memory"),
                value: CmuxTaskManagerFormat.bytes(model.snapshot.total.residentBytes)
            )
            metric(
                title: String(localized: "taskManager.summary.processes", defaultValue: "Processes"),
                value: "\(model.snapshot.total.processCount)"
            )
            metric(
                title: String(localized: "taskManager.summary.updated", defaultValue: "Updated"),
                value: model.snapshot.updatedText
            )
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func metric(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.body, design: .monospaced).weight(.semibold))
                .monospacedDigit()
        }
    }

    private var tableHeader: some View {
        HStack(spacing: 10) {
            Text(String(localized: "taskManager.column.name", defaultValue: "Name"))
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(String(localized: "taskManager.column.cpu", defaultValue: "CPU"))
                .frame(width: 82, alignment: .trailing)
            Text(String(localized: "taskManager.column.memory", defaultValue: "Memory"))
                .frame(width: 96, alignment: .trailing)
            Text(String(localized: "taskManager.column.processes", defaultValue: "Proc"))
                .frame(width: 58, alignment: .trailing)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var tableBody: some View {
        if let errorMessage = model.errorMessage {
            CmuxTaskManagerMessageView(
                title: String(localized: "taskManager.error.title", defaultValue: "Unable to load resource usage"),
                detail: errorMessage
            )
        } else if model.snapshot.rows.isEmpty {
            CmuxTaskManagerMessageView(
                title: String(localized: "taskManager.empty.title", defaultValue: "No resource usage"),
                detail: String(localized: "taskManager.empty.detail", defaultValue: "Open a workspace, terminal, or browser surface to see it here.")
            )
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.snapshot.rows) { row in
                        CmuxTaskManagerRowView(row: row)
                        Divider()
                            .padding(.leading, 16)
                    }
                }
            }
        }
    }
}

private struct CmuxTaskManagerMessageView: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 8) {
            Text(title)
                .font(.headline)
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }
}

private struct CmuxTaskManagerRowView: View {
    let row: CmuxTaskManagerRow

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 7) {
                Color.clear
                    .frame(width: CGFloat(row.level) * 18)
                Image(systemName: row.kind.systemImage)
                    .foregroundStyle(row.kind.tint)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.title)
                        .font(.system(.body))
                        .lineLimit(1)
                    if !row.detail.isEmpty {
                        Text(row.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(CmuxTaskManagerFormat.cpu(row.resources.cpuPercent))
                .frame(width: 82, alignment: .trailing)
            Text(CmuxTaskManagerFormat.bytes(row.resources.residentBytes))
                .frame(width: 96, alignment: .trailing)
            Text("\(row.resources.processCount)")
                .frame(width: 58, alignment: .trailing)
        }
        .font(.system(.body, design: .default))
        .monospacedDigit()
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .opacity(row.isDimmed ? 0.68 : 1)
    }
}

private struct CmuxTaskManagerSnapshot {
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
        for process in processes {
            appendProcess(process, level: 3, to: &rows)
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
        if webviews.isEmpty {
            let processes = surface["processes"] as? [[String: Any]] ?? []
            for process in processes {
                appendProcess(process, level: 4, to: &rows)
            }
        } else {
            for webview in webviews {
                appendWebView(webview, to: &rows)
            }
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
        for process in processes {
            appendProcess(process, level: 5, to: &rows)
        }
    }

    private static func appendProcess(_ process: [String: Any], level: Int, to rows: inout [CmuxTaskManagerRow]) {
        let pid = int(process["pid"])
        let title = nonEmptyString(process["name"])
            ?? pid.map { String(localized: "taskManager.row.processWithPID", defaultValue: "Process \($0)") }
            ?? String(localized: "taskManager.row.process", defaultValue: "Process")
        let detail = pid.map {
            String(localized: "taskManager.row.pid", defaultValue: "PID \($0)")
        } ?? ""
        rows.append(row(process, kind: .process, level: level, title: title, detail: detail))

        let children = process["children"] as? [[String: Any]] ?? []
        for child in children {
            appendProcess(child, level: level + 1, to: &rows)
        }
    }

    private static func row(
        _ payload: [String: Any],
        kind: CmuxTaskManagerRow.Kind,
        level: Int,
        title: String,
        detail: String,
        isDimmed: Bool = false
    ) -> CmuxTaskManagerRow {
        CmuxTaskManagerRow(
            id: rowID(payload, kind: kind),
            kind: kind,
            level: level,
            title: title,
            detail: detail,
            resources: CmuxTaskManagerResources(payload["resources"] as? [String: Any] ?? [:]),
            isDimmed: isDimmed
        )
    }

    private static func rowID(_ payload: [String: Any], kind: CmuxTaskManagerRow.Kind) -> String {
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

private struct CmuxTaskManagerRow: Identifiable {
    enum Kind: String {
        case window
        case workspace
        case tag
        case pane
        case terminalSurface
        case browserSurface
        case webview
        case process

        var systemImage: String {
            switch self {
            case .window: return "macwindow"
            case .workspace: return "rectangle.stack"
            case .tag: return "tag"
            case .pane: return "square.split.2x1"
            case .terminalSurface: return "terminal"
            case .browserSurface: return "globe"
            case .webview: return "network"
            case .process: return "gearshape"
            }
        }

        var tint: Color {
            switch self {
            case .window: return .secondary
            case .workspace: return .accentColor
            case .tag: return .orange
            case .pane: return .secondary
            case .terminalSurface: return .green
            case .browserSurface: return .blue
            case .webview: return .purple
            case .process: return .secondary
            }
        }
    }

    let id: String
    let kind: Kind
    let level: Int
    let title: String
    let detail: String
    let resources: CmuxTaskManagerResources
    let isDimmed: Bool
}

private struct CmuxTaskManagerResources {
    static let zero = CmuxTaskManagerResources(cpuPercent: 0, residentBytes: 0, processCount: 0)

    let cpuPercent: Double
    let residentBytes: Int64
    let processCount: Int

    init(cpuPercent: Double, residentBytes: Int64, processCount: Int) {
        self.cpuPercent = cpuPercent
        self.residentBytes = residentBytes
        self.processCount = processCount
    }

    init(_ payload: [String: Any]) {
        self.cpuPercent = Self.double(payload["cpu_percent"])
        self.residentBytes = Self.int64(payload["resident_bytes"])
        self.processCount = Self.int(payload["process_count"]) ?? 0
    }

    private static func double(_ raw: Any?) -> Double {
        if let value = raw as? Double { return value }
        if let value = raw as? NSNumber { return value.doubleValue }
        if let value = raw as? String,
           let parsed = Double(value.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return parsed
        }
        return 0
    }

    private static func int64(_ raw: Any?) -> Int64 {
        if let value = raw as? Int64 { return value }
        if let value = raw as? Int { return Int64(value) }
        if let value = raw as? NSNumber { return value.int64Value }
        if let value = raw as? String,
           let parsed = Int64(value.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return parsed
        }
        return 0
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

private enum CmuxTaskManagerFormat {
    private static let isoFormatter = ISO8601DateFormatter()
    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .medium
        formatter.dateStyle = .none
        return formatter
    }()

    static func cpu(_ value: Double) -> String {
        String(format: "%.1f%%", max(0, value))
    }

    static func bytes(_ bytes: Int64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = Double(max(0, bytes))
        var unitIndex = 0
        while value >= 1024, unitIndex < units.count - 1 {
            value /= 1024
            unitIndex += 1
        }
        if unitIndex == 0 {
            return "\(Int(value)) \(units[unitIndex])"
        }
        return String(format: "%.1f %@", value, units[unitIndex])
    }

    static func iso8601Date(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        return isoFormatter.date(from: raw)
    }

    static func time(_ date: Date) -> String {
        timeFormatter.string(from: date)
    }
}
