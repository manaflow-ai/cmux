import Foundation

// The surface model: terminals, VNC displays and browsers are *resources*; panes are
// *projections* of them. A resource has exactly one identity and zero or more
// projections, on this Mac or on a cloud machine. Every entrypoint — the right-sidebar
// tree, drag and drop, the socket, the CLI — reads and mutates the same catalog, so
// "is this terminal open somewhere?" has one answer and closing a pane never destroys a
// remote resource. Pure values here; the owner is `SurfaceCatalog`.

/// Where a resource lives. `.local` is this Mac; `.cloud` is a cmux Cloud machine id.
enum SurfaceMachineID: Hashable, Codable, Sendable, CustomStringConvertible {
    case local
    case cloud(String)

    var description: String {
        switch self {
        case .local: return "local"
        case .cloud(let id): return id
        }
    }

    /// Wire form: `"local"` or the machine id.
    var rawValue: String { description }

    init(rawValue: String) {
        self = rawValue == "local" ? .local : .cloud(rawValue)
    }

    var isLocal: Bool { if case .local = self { return true } else { return false } }
    var cloudMachineID: String? { if case .cloud(let id) = self { return id } else { return nil } }
}

enum SurfaceResourceKind: String, Codable, Sendable, CaseIterable {
    case terminal
    /// A VNC display on the machine ("display", never "screen": a cmux-tui `screen` is a
    /// split tree inside a workspace, a different thing).
    case display
    case browser

    /// Wire-tolerant parse: pre-rename catalogs, persisted sessions, and older CLIs say
    /// `screen` for a VNC display. Emit `display`, accept both.
    init?(wire: String) {
        if wire == "screen" {
            self = .display
            return
        }
        self.init(rawValue: wire)
    }

    init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let kind = SurfaceResourceKind(wire: raw) else {
            throw DecodingError.dataCorrupted(DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "Unknown surface resource kind '\(raw)'"
            ))
        }
        self = kind
    }
}

/// Stable identity of a resource. `key` is the provider's own id: a local panel UUID
/// string, a cmux-tui `term_…`/`browser_…` id, `display:1` for a VNC display, or
/// `port:<n>` for a forwarded port's browser.
struct SurfaceResourceID: Hashable, Codable, Sendable, CustomStringConvertible {
    var machine: SurfaceMachineID
    var kind: SurfaceResourceKind
    var key: String

    var description: String { "\(machine.rawValue)/\(kind.rawValue)/\(key)" }

    /// Wire form `<machine>/<kind>/<key>`; keys may contain `/` (URLs), so split only twice.
    var rawValue: String { description }

    init(machine: SurfaceMachineID, kind: SurfaceResourceKind, key: String) {
        self.machine = machine
        self.kind = kind
        self.key = key
    }

    init?(rawValue: String) {
        let parts = rawValue.split(separator: "/", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, let kind = SurfaceResourceKind(wire: String(parts[1])), !parts[2].isEmpty else { return nil }
        self.init(machine: SurfaceMachineID(rawValue: String(parts[0])), kind: kind, key: String(parts[2]))
    }
}

enum SurfaceLifecycle: String, Codable, Sendable {
    case launching
    case running
    case exited
    /// The machine is asleep or its link is down; the resource is known but not reachable now.
    case unavailable
}

struct SurfaceAgentBadge: Hashable, Codable, Sendable {
    var state: String
    var source: String?
}

/// The cmux-tui workspace a remote resource belongs to (nil for local resources).
struct SurfaceRemoteWorkspace: Hashable, Codable, Sendable {
    var id: String
    var name: String
    var index: Int
    var focused: Bool
}

/// One view of a remote resource: a tab in one of the daemon's workspaces. A resource
/// has zero or more views; closing a view never kills the resource.
struct SurfaceRemoteView: Hashable, Codable, Sendable {
    var tabID: String
    var workspace: SurfaceRemoteWorkspace
}

struct SurfaceResource: Identifiable, Hashable, Codable, Sendable {
    var id: SurfaceResourceID
    var title: String
    /// cwd for terminals, URL for browsers, display name for screens.
    var detail: String?
    var lifecycle: SurfaceLifecycle
    var agent: SurfaceAgentBadge?
    /// The workspace of the resource's first view (compat: pre-multi-view callers read
    /// one workspace). nil when the resource has zero views, or is local.
    var remoteWorkspace: SurfaceRemoteWorkspace?
    /// Every view of a remote resource, in the daemon's canonical tab order. nil when the
    /// provider does not model views (local resources, displays, port browsers); an empty
    /// array is a live resource with zero views (it belongs in the machine's pool).
    var remoteViews: [SurfaceRemoteView]? = nil
    /// For screens and port browsers: the port on the machine.
    var port: Int?
    /// For browsers: the URL the projection loads. Screens resolve their URL when projected
    /// (the control plane mints a tokened wrapper URL), so it stays nil here.
    var url: String?

    var machine: SurfaceMachineID { id.machine }
    var kind: SurfaceResourceKind { id.kind }

    /// How many remote views (daemon tabs) show this resource; 0 when views are not modeled.
    var remoteViewCount: Int { remoteViews?.count ?? 0 }

    /// The daemon workspaces holding at least one view, first-view order, deduped.
    /// Falls back to `remoteWorkspace` for providers that report a single workspace.
    var remoteWorkspaces: [SurfaceRemoteWorkspace] {
        guard let remoteViews else { return remoteWorkspace.map { [$0] } ?? [] }
        var seen = Set<String>()
        var result: [SurfaceRemoteWorkspace] = []
        for view in remoteViews where seen.insert(view.workspace.id).inserted {
            result.append(view.workspace)
        }
        return result
    }
}

/// One pane showing one resource.
struct SurfaceProjection: Hashable, Codable, Sendable {
    var resource: SurfaceResourceID
    var workspaceID: UUID
    var panelID: UUID
}

enum SurfaceSplitDirection: String, Codable, Sendable {
    case left, right, up, down
}

/// Where to project. Mirrors the socket params `workspace_id` / `pane_id` / `direction` /
/// `tab_index`; `.workspace` splits that workspace's focused pane to the right (or tabs
/// when `placement` is `.tab`).
enum SurfaceDestination: Hashable, Sendable {
    case workspace(id: UUID, placement: SurfacePlacement)
    case split(workspaceID: UUID, paneID: String, direction: SurfaceSplitDirection)
    case tab(workspaceID: UUID, paneID: String, index: Int?)

    var workspaceID: UUID {
        switch self {
        case .workspace(let id, _): return id
        case .split(let id, _, _): return id
        case .tab(let id, _, _): return id
        }
    }
}

enum SurfacePlacement: String, Codable, Sendable {
    case split
    case tab
}

/// What a provider knows about its machine, for the tree header.
struct SurfaceMachineInfo: Hashable, Codable, Sendable {
    var id: SurfaceMachineID
    var name: String
    /// `running`, `standby`, … for cloud machines; `running` for the local Mac.
    var status: String
    var image: String?
    var hasDesktop: Bool
    var memoryMb: Int?
    var diskMb: Int?
    var linkState: SurfaceLinkState
    var linkError: String?
    var cpuPercent: Double?
    var memoryUsedMb: Int?
    var diskUsedMb: Int?
    /// Every cmux-tui workspace on the machine, in the daemon's order — including empty
    /// ones, which have no terminal to be derived from. nil when unknown (asleep, local).
    var remoteWorkspaces: [SurfaceRemoteWorkspace]? = nil
}

enum SurfaceLinkState: String, Codable, Sendable {
    case connected
    case connecting
    case asleep
    case unavailable
    case error
    /// The local Mac needs no link.
    case notApplicable = "n/a"
}

/// The catalog as one value: what the sidebar renders, what `surface.catalog` and
/// `cmux vm tree --json` print. Machines are ordered local first, then by name.
struct SurfaceCatalogSnapshot: Hashable, Codable, Sendable {
    var machines: [SurfaceMachineInfo]
    var resources: [SurfaceResource]
    var projections: [SurfaceProjection]

    static let empty = SurfaceCatalogSnapshot(machines: [], resources: [], projections: [])

    func resources(on machine: SurfaceMachineID) -> [SurfaceResource] {
        resources.filter { $0.machine == machine }
    }

    func projections(of resource: SurfaceResourceID) -> [SurfaceProjection] {
        projections.filter { $0.resource == resource }
    }

    func isOpen(_ resource: SurfaceResourceID) -> Bool {
        projections.contains { $0.resource == resource }
    }
}

/// Persisted with the session: which resource each pane projected, so a restored pane
/// re-projects a remote resource instead of becoming an anonymous shell.
struct SurfaceProjectionRecord: Hashable, Codable, Sendable {
    var panelID: UUID
    var resource: SurfaceResourceID
}

enum SurfaceCatalogError: Error, LocalizedError, Equatable {
    case unknownResource(SurfaceResourceID)
    case noProvider(SurfaceMachineID)
    case unavailable(SurfaceResourceID, reason: String)
    case destinationNotFound(String)
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case .unknownResource(let id): return "Unknown surface \(id)."
        case .noProvider(let machine): return "No provider for machine \(machine)."
        case .unavailable(let id, let reason): return "\(id) is unavailable: \(reason)"
        case .destinationNotFound(let what): return "Destination not found: \(what)."
        case .unsupported(let what): return "Unsupported: \(what)."
        }
    }
}

/// Preview endpoints already minted for one machine's HTTP ports (the desktop's noVNC on
/// 6901, daemon browsers on theirs). `POST /api/vm/<id>/open-port` mints a 7-day preview
/// token behind three provider round trips, which is the whole wait between dropping a
/// display row and seeing its pane. An entry is reused until `ttl` elapses (well inside
/// the token's life) and dies with its provider, so a deleted machine never serves a
/// stale URL. Stores the raw `openUrl`; callers add display parameters on read.
struct SurfacePortEndpointCache: Sendable {
    struct Entry: Equatable, Sendable {
        let openURL: String
        let expiresAt: Date
    }

    /// Six hours: far under the token's 7 days, long enough that a machine open all day
    /// mints a handful of leases, not one per drop.
    static let defaultTTL: TimeInterval = 6 * 60 * 60

    private(set) var entries: [Int: Entry] = [:]
    let ttl: TimeInterval

    init(ttl: TimeInterval = SurfacePortEndpointCache.defaultTTL) {
        self.ttl = ttl
    }

    /// The cached `openUrl` for `port`, or nil once its entry has expired.
    func openURL(port: Int, now: Date = Date()) -> String? {
        guard let entry = entries[port], entry.expiresAt > now else { return nil }
        return entry.openURL
    }

    mutating func store(openURL: String, port: Int, now: Date = Date()) {
        entries[port] = Entry(openURL: openURL, expiresAt: now.addingTimeInterval(ttl))
    }

    mutating func invalidate(port: Int) {
        entries[port] = nil
    }
}
