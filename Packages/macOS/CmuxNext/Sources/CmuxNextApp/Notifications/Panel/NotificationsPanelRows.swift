import CmuxNextDaemon
import Foundation

/// One row of the notifications panel: a daemon ledger entry
/// (`list-notifications`) with the workspace it came from.
struct NotificationsPanelRow: Hashable, Identifiable {
    let id: String
    let title: String
    let subtitle: String?
    let body: String
    let level: NotificationLevel
    /// The source workspace's sidebar title, when its tab still exists.
    let workspaceTitle: String?
    let createdAt: Date
    let unread: Bool
    /// The tab that showed it, for Open and Mark as Read.
    let surface: SurfaceID?
    /// The terminal's public id (`term_…`), for Clear.
    let terminal: String?

    /// Every ledger entry, newest first (the daemon's order). `workspace`
    /// names the workspace of a tab that still exists.
    static func make(_ entries: [ListNotificationsRequest.Entry],
                     workspace: (SurfaceID) -> String?) -> [NotificationsPanelRow] {
        entries.sorted { $0.createdAtMs > $1.createdAtMs }.map { entry in
            NotificationsPanelRow(
                id: entry.id,
                title: entry.title,
                subtitle: entry.subtitle.flatMap { $0.isEmpty ? nil : $0 },
                body: entry.body,
                level: entry.level,
                workspaceTitle: entry.surface.flatMap(workspace),
                createdAt: Date(timeIntervalSince1970: TimeInterval(entry.createdAtMs) / 1000),
                unread: !entry.acknowledged,
                surface: entry.surface,
                terminal: entry.terminalID?.rawValue
            )
        }
    }

    /// The text Copy puts on the pasteboard.
    var copyText: String {
        [title, subtitle, body.isEmpty ? nil : body].compactMap { $0 }.joined(separator: "\n")
    }
}

/// Keyboard selection in the panel: moves with the arrows, stays on the
/// same notification across reloads, and falls back to the nearest row
/// when that one leaves.
struct NotificationsPanelSelection: Equatable {
    private(set) var id: String?

    mutating func move(by offset: Int, in rows: [NotificationsPanelRow]) {
        guard !rows.isEmpty else { id = nil; return }
        let current = id.flatMap { id in rows.firstIndex { $0.id == id } }
        let next = current.map { min(max($0 + offset, 0), rows.count - 1) } ?? (offset < 0 ? rows.count - 1 : 0)
        id = rows[next].id
    }

    /// Keeps the selection on its row, or the row now at its old index.
    mutating func reconcile(old: [NotificationsPanelRow], new: [NotificationsPanelRow]) {
        guard let id else { return }
        if new.contains(where: { $0.id == id }) { return }
        guard !new.isEmpty, let index = old.firstIndex(where: { $0.id == id }) else { self.id = nil; return }
        self.id = new[min(index, new.count - 1)].id
    }

    func index(in rows: [NotificationsPanelRow]) -> Int? {
        id.flatMap { id in rows.firstIndex { $0.id == id } }
    }
}
