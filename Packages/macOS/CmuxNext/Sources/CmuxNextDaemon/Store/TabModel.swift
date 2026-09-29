import Foundation
public import Observation
import os

// Main-actor mirror of the daemon tree. Models are keyed by durable ids
// (workspace key, resource ids, tab resource id), so a resync after a
// reconnect or daemon restart updates the same objects in place and views
// keep their identity. Numeric handles are refreshed on every snapshot.
//
// Focus, hover, drag, and scroll are not here: the daemon's `active*` fields
// are shared compatibility defaults, and user focus is client-local.

@Observable @MainActor
public final class TabModel: Identifiable {
    public let id: String
    public internal(set) var surface: SurfaceID
    public internal(set) var terminalID: TerminalID?
    public internal(set) var terminalIncarnation: TerminalIncarnation?
    /// Public terminal id (`term_…`) used by `attach-identity-v1`.
    public internal(set) var terminalResourceID: ResourceID?
    public internal(set) var kind: TabKind
    public internal(set) var name: String?
    public internal(set) var title: String
    public internal(set) var size: CellSize?
    public internal(set) var dead: Bool
    public internal(set) var notification: TabNotification?
    public internal(set) var url: String?
    public internal(set) var pinned: Bool
    public internal(set) var cwd: String?
    public internal(set) var gitBranch: String?
    public internal(set) var gitDetached: Bool = false
    public internal(set) var browserEngine: String?
    public internal(set) var faviconURL: String?
    public internal(set) var isFrontendOwned: Bool
    public internal(set) var agent: AgentStatus?
    /// Last snapshot, for fields the model does not surface.
    public internal(set) var snapshot: TabSnapshot

    public var displayTitle: String {
        if let name, !name.isEmpty { return name }
        return title
    }

    public var hasUnread: Bool { notification?.unread == true }

    init(_ snapshot: TabSnapshot) {
        id = Self.identity(snapshot)
        surface = snapshot.surface
        kind = snapshot.kind
        title = snapshot.title
        dead = snapshot.dead
        pinned = snapshot.pinned
        isFrontendOwned = snapshot.isFrontendOwned
        self.snapshot = snapshot
        update(snapshot)
    }

    static func identity(_ snapshot: TabSnapshot) -> String {
        snapshot.tabResourceID?.rawValue ?? snapshot.terminalID.map { "terminal:\($0.rawValue)" } ?? "surface:\(snapshot.surface.rawValue)"
    }

    func update(_ snapshot: TabSnapshot) {
        self.snapshot = snapshot
        surface = snapshot.surface
        terminalID = snapshot.terminalID
        terminalIncarnation = snapshot.terminalIncarnation
        terminalResourceID = snapshot.terminalResourceID
        kind = snapshot.kind
        name = snapshot.name
        title = snapshot.title
        size = snapshot.size
        dead = snapshot.dead
        notification = snapshot.notification
        url = snapshot.url
        pinned = snapshot.pinned
        cwd = snapshot.cwd
        gitBranch = snapshot.gitBranch
        gitDetached = snapshot.gitDetached
        browserEngine = snapshot.browserEngine
        faviconURL = snapshot.faviconURL
        isFrontendOwned = snapshot.isFrontendOwned
    }
}
