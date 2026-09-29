import Foundation
public import Observation
import os

@Observable @MainActor
public final class WorkspaceModel: Identifiable {
    /// Durable key (or `handle:<n>` on servers without the registry).
    public let id: String
    public internal(set) var key: WorkspaceKey?
    public internal(set) var handle: WorkspaceHandle
    public internal(set) var name: String
    public internal(set) var screens: [ScreenModel]
    public internal(set) var group: WorkspaceGroupID?
    public internal(set) var color: String?
    public internal(set) var icon: String?
    public internal(set) var title: String?

    /// Custom title when set, else the name.
    public var displayName: String {
        if let title, !title.isEmpty { return title }
        return name
    }

    init(_ snapshot: WorkspaceSnapshot) {
        id = Self.identity(snapshot)
        key = snapshot.key
        handle = snapshot.id
        name = snapshot.name
        screens = snapshot.screens.map(ScreenModel.init)
        group = snapshot.group
        color = snapshot.color
        icon = snapshot.icon
        title = snapshot.title
    }

    static func identity(_ snapshot: WorkspaceSnapshot) -> String {
        snapshot.key?.rawValue ?? "handle:\(snapshot.id.rawValue)"
    }

    func update(_ snapshot: WorkspaceSnapshot) {
        key = snapshot.key
        handle = snapshot.id
        name = snapshot.name
        group = snapshot.group
        color = snapshot.color
        icon = snapshot.icon
        title = snapshot.title
        screens = reconcile(screens, with: snapshot.screens, id: ScreenModel.identity, make: ScreenModel.init) { $0.update($1) }
    }

    /// Unread tabs in this workspace.
    public var unreadCount: Int {
        screens.reduce(0) { total, screen in
            total + screen.panes.reduce(0) { $0 + $1.tabs.filter(\.hasUnread).count }
        }
    }
}
