import CmuxNextDesign
package import Foundation

/// The saved identity and appearance of a workspace row, and what sets its height and its Done fold: the
/// second line's facts, the reported status block, the progress bar and the task status. A relaunch's first
/// frame lays each row out as its live row will, so the live tree's arrival moves no row (Leo 2026-11-07:
/// "Like, it was already loaded, and then it flickered."). Each saved text is cut to `textLimit` characters
/// (a row draws one line of each) and the status block to the lines a row draws; the rest arrives from the daemon.
package nonisolated struct SidebarWorkspaceSnapshot: Codable, Hashable, Sendable {
    package var id: String
    package var machineID: String
    package var title: String
    /// `harness`, `browser` or `terminal`; absent in older snapshots.
    package var kind: String?
    /// The agent brand whose mark is the row's type glyph; absent in older snapshots.
    package var kindBrand: String?
    /// `symbol:<name>`, `swatch:<color>`, `emoji:<text>`, or `page:` for a page's favicon slot (restored as its globe).
    package var icon: String?
    package var iconTint: String?
    /// The workspace's own color, for a filled or railed row; absent in older snapshots.
    package var color: String?
    /// The row's second-line facts (`WorkspaceRowContent.text(of:in:now:)`); each absent in older snapshots.
    package var directory: String?
    package var branch: String?
    package var process: String?
    package var status: String?
    package var ports: String?
    package var pullRequest: String?
    package var notificationText: String?
    package var lastActivity: Date?
    /// The description's first line: an expanded row's second line.
    package var descriptionLine: String?
    /// `WorkspaceRowKind`'s raw value: which per-kind row settings apply.
    package var rowKind: String?
    /// The bar's fraction and its error state, saved only when the row draws a bar.
    package var progress: Double?
    package var progressIsError: Bool?
    /// `SidebarTaskStatus`'s raw value: a Done row restores inside the Done fold.
    package var taskStatus: String?
    /// The status block's lines; absent when nothing is reported.
    private var reported: Reported?

    /// The longest saved text: a row draws one truncated line of each.
    static let textLimit = 200
    /// The most entries saved past the drawn ones' count: the "N more" line only counts them.
    static let hiddenEntryLimit = 999

    /// What the status block draws (`SidebarWorkspaceStatus.lines`): the drawn entries, how many more
    /// fold into "N more", the log line and the progress label. Icons and images arrive live.
    private nonisolated struct Reported: Codable, Hashable, Sendable {
        var entries: [Entry]?
        var hiddenEntries: Int?
        var log: String?
        var logLevel: String?
        var progressLabel: String?

        nonisolated struct Entry: Codable, Hashable, Sendable {
            var key: String
            var text: String
        }

        init(_ status: SidebarWorkspaceStatus) {
            let shown = status.entries.prefix(SidebarWorkspaceStatus.visibleEntryLimit)
            let entries = shown.map {
                Entry(key: SidebarWorkspaceSnapshot.cut($0.key) ?? "", text: SidebarWorkspaceSnapshot.cut($0.text) ?? "")
            }
            self.entries = entries.isEmpty ? nil : entries
            let hidden = min(status.entries.count - shown.count, SidebarWorkspaceSnapshot.hiddenEntryLimit)
            hiddenEntries = hidden > 0 ? hidden : nil
            log = status.log.flatMap { SidebarWorkspaceSnapshot.cut($0.text) }
            logLevel = status.log?.level.rawValue
            progressLabel = SidebarWorkspaceSnapshot.cut(status.progressLabel)
        }

        var status: SidebarWorkspaceStatus? {
            var rows = (entries ?? []).map { SidebarWorkspaceStatus.Entry(key: $0.key, text: $0.text) }
            // Blank entries stand for the folded ones: the row counts them in its "N more" line.
            let hidden = max(0, min(hiddenEntries ?? 0, SidebarWorkspaceSnapshot.hiddenEntryLimit))
            rows += Array(repeating: SidebarWorkspaceStatus.Entry(key: "", text: ""), count: hidden)
            let level = logLevel.flatMap(SidebarWorkspaceStatus.LogLevel.init(rawValue:)) ?? .info
            let line = log.map { SidebarWorkspaceStatus.LogLine(level: level, text: $0) }
            let status = SidebarWorkspaceStatus(entries: rows, log: line, progressLabel: progressLabel)
            return status.isEmpty ? nil : status
        }
    }

    package init(id: String, machineID: String, title: String, kind: String? = nil,
                 kindBrand: String? = nil, icon: String? = nil, iconTint: String? = nil, color: String? = nil) {
        self.id = id
        self.machineID = machineID
        self.title = title
        self.kind = kind
        self.kindBrand = kindBrand
        self.icon = icon
        self.iconTint = iconTint
        self.color = color
    }

    /// What `row` shows that a relaunch draws in its first frame. A page's favicon (or its globe) is saved as the
    /// page slot alone: the restored row draws the globe in the icon column, so its title starts where it stays and
    /// the live favicon replaces the globe in place.
    package init(row ws: SidebarWorkspace) {
        var icon: String?
        var tint: String?
        switch ws.icon {
        case let .symbol(name, color)?:
            icon = "symbol:" + name
            tint = color?.rawValue
        case let .swatch(color)?: icon = "swatch:" + color.rawValue
        case let .emoji(text, chip)?:
            icon = "emoji:" + text
            tint = chip?.rawValue
        // Off a page row, a favicon is the workspace's own image or SVG icon: its loading symbol keeps the column.
        // A row whose focused tab is a page (beside a chat or terminal) shows that page's favicon.
        case .favicon? where ws.kind != .browser && !Self.focusesPage(ws): icon = "symbol:photo"
        case .favicon?, .pagePlaceholder?: icon = Self.pageIcon
        case nil: break
        }
        self.init(id: ws.id.rawValue, machineID: ws.machineID.rawValue, title: ws.title,
                  kind: ws.kind.rawValue, kindBrand: ws.kindBrand, icon: icon, iconTint: tint, color: ws.color?.rawValue)
        directory = Self.cut(ws.directory)
        branch = Self.cut(ws.branch)
        process = Self.cut(ws.process)
        status = Self.cut(ws.status)
        ports = Self.cut(ws.ports)
        pullRequest = Self.cut(ws.pullRequest)
        notificationText = Self.cut(ws.notificationText)
        lastActivity = ws.lastActivity
        descriptionLine = Self.cut(WorkspaceRowContent.descriptionLine(ws))
        rowKind = ws.rowKind == ws.kind.rowKind ? nil : ws.rowKind.rawValue
        if let bar = ws.progress, bar.value != nil || bar.isError {
            progress = bar.value
            progressIsError = bar.isError ? true : nil
        }
        taskStatus = ws.taskStatus?.rawValue
        reported = ws.reported.map(Reported.init).flatMap { $0.status == nil ? nil : $0 }
    }

    /// The saved row, `.stale` until the live tree replaces it.
    package var restoredRow: SidebarWorkspace {
        var row = SidebarWorkspace(
            id: WorkspaceID(id), machineID: MachineID(machineID), title: title, directory: directory, branch: branch,
            process: process, status: status, ports: ports, pullRequest: pullRequest, lastActivity: lastActivity,
            rowKind: rowKind.flatMap(WorkspaceRowKind.init(rawValue:)),
            icon: icon.flatMap { Self.icon($0, tint: iconTint) }, color: color.flatMap(GroupColor.init(rawValue:)),
            kind: SidebarWorkspaceKind(rawValue: kind ?? "terminal") ?? .terminal,
            kindBrand: kindBrand, progress: progress != nil || progressIsError == true
                ? SidebarProgress(value: progress, isError: progressIsError ?? false) : nil,
            rowState: .stale)
        row.notificationText = notificationText
        row.workspaceDescription = descriptionLine
        row.taskStatus = taskStatus.flatMap(SidebarTaskStatus.init(rawValue:))
        row.reported = reported?.status
        return row
    }

    /// `text` cut to `textLimit` characters; nil when empty.
    static func cut(_ text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        return text.count > textLimit ? String(text.prefix(textLimit)) : text
    }

    /// The saved icon of a row that showed a page's favicon or its placeholder globe.
    static let pageIcon = "page:"

    /// Whether `row`'s focused tab is a page, whose favicon is then the row's icon (`SidebarMapping.faceRow`).
    static func focusesPage(_ row: SidebarWorkspace) -> Bool {
        guard let focused = row.focusedTab else { return false }
        return row.tabs.first { $0.id == focused }?.kind == .browser
    }

    private static func icon(_ value: String, tint: String?) -> WorkspaceIcon? {
        if value == pageIcon { return .pagePlaceholder }
        guard let colon = value.firstIndex(of: ":") else { return nil }
        let kind = value[..<colon]
        let rest = String(value[value.index(after: colon)...])
        switch kind {
        case "symbol": return .symbol(rest, tint: tint.flatMap(GroupColor.init(rawValue:)))
        case "swatch": return GroupColor(rawValue: rest).map(WorkspaceIcon.swatch)
        case "emoji": return .emoji(rest, chip: tint.flatMap(GroupColor.init(rawValue:)))
        default: return nil
        }
    }
}
