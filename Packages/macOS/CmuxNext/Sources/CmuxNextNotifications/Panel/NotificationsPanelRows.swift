package import CmuxNextDaemon
import CmuxNextSettings
package import Foundation

/// One row of the notifications panel: a daemon ledger entry
/// (`list-notifications`) with the workspace it came from.
package struct NotificationsPanelRow: Hashable, Identifiable {
    package let id: String
    package let title: String
    package let subtitle: String?
    package let body: String
    package let level: NotificationLevel
    /// The producer the daemon named for the row (`source`).
    package let source: String?
    /// The source workspace's sidebar title, when its tab still exists.
    package let workspaceTitle: String?
    package let createdAt: Date
    package let unread: Bool
    /// The tab that showed it, for Open and Mark as Read.
    package let surface: SurfaceID?
    /// The terminal's public id (`term_…`), for Clear.
    package let terminal: String?

    package init(id: String, title: String, subtitle: String?, body: String, level: NotificationLevel, source: String?,
                 workspaceTitle: String?, createdAt: Date, unread: Bool, surface: SurfaceID?, terminal: String?) {
        (self.id, self.title, self.subtitle, self.body, self.level, self.source) = (id, title, subtitle, body, level, source)
        (self.workspaceTitle, self.createdAt, self.unread, self.surface, self.terminal) = (workspaceTitle, createdAt, unread, surface, terminal)
    }

    /// The producer's name, the one Settings gives it, so a row reads the way
    /// the `notifications.sources.<source>` setting that governs it does.
    /// `NotificationSource(wire:)` decides, the one wire mapping, so `daemon`
    /// and a value this build does not know read as agent-side, as they do
    /// everywhere else.
    package var sourceLabel: String? {
        guard let source, !source.isEmpty else { return nil }
        return NotificationSource(wire: source).settingsTitle.text
    }

    /// Every ledger entry, newest first (the daemon's order). `workspace`
    /// names the workspace of a tab that still exists.
    package static func make(_ entries: [ListNotificationsRequest.Entry],
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
    package var copyText: String {
        [title, sourceLabel, subtitle, body.isEmpty ? nil : body].compactMap { $0 }.joined(separator: "\n")
    }
}

/// Keyboard selection in the panel: moves with the arrows, stays on the
/// same notification across reloads, and falls back to the nearest row
/// when that one leaves.
package struct NotificationsPanelSelection: Equatable {
    package private(set) var id: String?

    package init() {}

    @MainActor package mutating func move(by offset: Int, in list: NotificationsPanelList) {
        guard list.count > 0 else { id = nil; return }
        let current = id.flatMap(list.index(of:))
        let next = current.map { min(max($0 + offset, 0), list.count - 1) } ?? (offset < 0 ? list.count - 1 : 0)
        id = list.row(at: next).id
    }

    /// Keeps the selection on its row, or the row now at `oldIndex`, its index before the list changed.
    @MainActor package mutating func reconcile(oldIndex: Int?, in list: NotificationsPanelList) {
        guard let id, list.index(of: id) == nil else { return }
        guard list.count > 0, let oldIndex else { self.id = nil; return }
        self.id = list.row(at: min(oldIndex, list.count - 1)).id
    }

    @MainActor package func index(in list: NotificationsPanelList) -> Int? {
        id.flatMap(list.index(of:))
    }
}
