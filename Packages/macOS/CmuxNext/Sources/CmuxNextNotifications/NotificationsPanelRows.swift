public import CmuxNextDaemon
import CmuxNextSettings
import CmuxNextWindowRules
public import Foundation

/// One row of the notifications panel: a daemon ledger entry
/// (`list-notifications`) with the workspace it came from.
public struct NotificationsPanelRow: Hashable, Identifiable {
    public let id: String
    public let title: String
    public let subtitle: String?
    public let body: String
    public let level: NotificationLevel
    /// The producer the daemon named for the row (`source`).
    public let source: String?
    /// The source workspace's sidebar title, when its tab still exists.
    public let workspaceTitle: String?
    public let createdAt: Date
    public let unread: Bool
    /// The tab that showed it, for Open and Mark as Read.
    public let surface: SurfaceID?
    /// The terminal's public id (`term_…`), for Clear.
    public let terminal: String?

    public init(id: String, title: String, subtitle: String?, body: String, level: NotificationLevel, source: String?,
                workspaceTitle: String?, createdAt: Date, unread: Bool, surface: SurfaceID?, terminal: String?) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.body = body
        self.level = level
        self.source = source
        self.workspaceTitle = workspaceTitle
        self.createdAt = createdAt
        self.unread = unread
        self.surface = surface
        self.terminal = terminal
    }

    /// The producer's name, the one Settings gives it, so a row reads the way
    /// the `notifications.sources.<source>` setting that governs it does.
    /// `NotificationSource(wire:)` decides, the one wire mapping, so `daemon`
    /// and a value this build does not know read as agent-side, as they do
    /// everywhere else.
    public var sourceLabel: String? {
        guard let source, !source.isEmpty else { return nil }
        return NotificationSource(wire: source).settingsTitle.text
    }

    /// Every ledger entry, newest first (the daemon's order). `workspace`
    /// names the workspace of a tab that still exists.
    public static func make(_ entries: [ListNotificationsRequest.Entry],
                     workspace: (SurfaceID) -> String?) -> [NotificationsPanelRow] {
        entries.sorted { $0.createdAtMs > $1.createdAtMs }.map { entry in
            NotificationsPanelRow(
                id: entry.id,
                title: entry.title,
                subtitle: entry.subtitle.flatMap { $0.isEmpty ? nil : $0 },
                body: entry.body,
                level: entry.level,
                source: entry.source,
                workspaceTitle: entry.surface.flatMap(workspace),
                createdAt: Date(timeIntervalSince1970: TimeInterval(entry.createdAtMs) / 1000),
                unread: !entry.acknowledged,
                surface: entry.surface,
                terminal: entry.terminalID?.rawValue
            )
        }
    }

    /// The text Copy puts on the pasteboard.
    public var copyText: String {
        [title, sourceLabel, subtitle, body.isEmpty ? nil : body].compactMap { $0 }.joined(separator: "\n")
    }
}

/// Keyboard selection in the panel: moves with the arrows, stays on the
/// same notification across reloads, and falls back to the nearest row
/// when that one leaves. The rules are Rust's (cmux-window-rules
/// `notifications_panel`, ops `window_notifications_panel_move` and `_panel_reconcile`).
public struct NotificationsPanelSelection: Equatable {
    public private(set) var id: String?

    public init() {}

    public mutating func move(by offset: Int, in rows: [NotificationsPanelRow]) {
        struct Request: Encodable { var selected: String?, offset: Int, rows: [String] }
        struct Reply: Decodable { var selected: String? }
        // An FFI without the op answers nothing: the selection stays where it is.
        guard let reply = WindowRules().call("window_notifications_panel_move", Request(selected: id, offset: offset, rows: rows.map(\.id)),
                                             as: Reply.self) else { return }
        id = reply.selected
    }

    /// Keeps the selection on its row, or the row now at its old index.
    public mutating func reconcile(old: [NotificationsPanelRow], new: [NotificationsPanelRow]) {
        guard let id else { return }
        struct Request: Encodable { var selected: String?, old: [String], new: [String] }
        struct Reply: Decodable { var selected: String? }
        let request = Request(selected: id, old: old.map(\.id), new: new.map(\.id))
        // An FFI without the op answers nothing: the selection is cleared rather than left on a row that went.
        self.id = WindowRules().call("window_notifications_panel_reconcile", request, as: Reply.self)?.selected
    }

    public func index(in rows: [NotificationsPanelRow]) -> Int? {
        id.flatMap { id in rows.firstIndex { $0.id == id } }
    }
}
