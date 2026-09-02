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

/// The daemon's monotonic position for one complete remote session state.
///
/// `revision` is encoded as a string because that is the cmux-tui wire form. The
/// decoder accepts both strings and JSON numbers so a client can read snapshots
/// from older daemon builds. A revision is meaningful only inside its generation.
struct CloudVMCursor: Hashable, Codable, Sendable {
    var generation: String
    var revision: UInt64

    init(generation: String, revision: UInt64) {
        self.generation = generation
        self.revision = revision
    }

    init?(snapshot: [String: Any]) {
        guard let cursor = snapshot["cursor"] as? [String: Any],
              let generation = (cursor["generation"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !generation.isEmpty,
              let revision = Self.revision(cursor["revision"])
        else { return nil }
        self.init(generation: generation, revision: revision)
    }

    init?(wire: [String: Any]) {
        guard let generation = (wire["generation"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !generation.isEmpty,
              let revision = Self.revision(wire["revision"])
        else { return nil }
        self.init(generation: generation, revision: revision)
    }

    private static func revision(_ raw: Any?) -> UInt64? {
        CloudWireNumber.unsigned(raw)
    }

    /// Returns true only when both cursors belong to the same daemon
    /// generation. Generations are opaque identifiers, so callers must never
    /// impose an ordering across them.
    func isNewer(than other: CloudVMCursor?) -> Bool {
        guard let other else { return true }
        return generation == other.generation && revision > other.revision
    }

    private enum CodingKeys: String, CodingKey {
        case generation
        case revision
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let generation = try container.decode(String.self, forKey: .generation)
        if let revision = try? container.decode(UInt64.self, forKey: .revision) {
            self.init(generation: generation, revision: revision)
        } else {
            let revision = try container.decode(String.self, forKey: .revision)
            guard let value = UInt64(revision) else {
                throw DecodingError.dataCorruptedError(forKey: .revision, in: container, debugDescription: "revision is not an unsigned integer")
            }
            self.init(generation: generation, revision: value)
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(generation, forKey: .generation)
        try container.encode(String(revision), forKey: .revision)
    }
}

/// Strictly decodes the integer forms used by the cmux-tui wire protocol.
/// JSONSerialization represents both booleans and numbers as NSNumber on some
/// paths. Coercing that value with intValue would turn `true`, fractions, and
/// overflowing values into a different cursor or index, which can make a delta
/// look contiguous when it is not.
enum CloudWireNumber {
    static func unsigned(_ raw: Any?) -> UInt64? {
        if raw is Bool { return nil }
        if let number = raw as? NSNumber {
            guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            guard number.doubleValue.isFinite,
                  number.doubleValue.rounded() == number.doubleValue,
                  number.doubleValue >= 0 else { return nil }
            if let value = raw as? UInt64 { return value }
            return UInt64(number.stringValue)
        }
        if let value = raw as? UInt64 { return value }
        if let value = raw as? Int, value >= 0 { return UInt64(value) }
        if let value = raw as? String { return UInt64(value.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return nil
    }

    static func signed(_ raw: Any?) -> Int? {
        if raw is Bool { return nil }
        if let number = raw as? NSNumber {
            guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            guard number.doubleValue.isFinite,
                  number.doubleValue.rounded() == number.doubleValue else { return nil }
            return Int(number.stringValue)
        }
        if let value = raw as? Int { return value }
        if let value = raw as? String { return Int(value.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return nil
    }
}

/// A daemon entity not yet modeled by the desktop. Its exact JSON is retained so
/// an agent or a future renderer can inspect it without waiting for a schema bump.
struct CloudVMEntity: Hashable, Codable, Sendable {
    var kind: String
    var id: String?
    var payload: Data
}

/// A typed index of the cmux-tui session graph. The raw snapshot remains the
/// authority; these values are immutable indexes used by the tree and agents.
struct CloudVMWorkspaceState: Hashable, Codable, Sendable {
    var id: String
    var name: String
    var index: Int
    var focused: Bool
}

struct CloudVMScreenState: Hashable, Codable, Sendable {
    var id: String
    var workspaceID: String
    var name: String?
    var index: Int
    var focused: Bool
    /// The daemon layout document, kept opaque because its schema can evolve.
    var layout: Data?
}

struct CloudVMPaneState: Hashable, Codable, Sendable {
    var id: String
    var screenID: String
    var name: String?
    var focused: Bool
    var zoomed: Bool
    var tabIDs: [String]
}

struct CloudVMTabState: Hashable, Codable, Sendable {
    var id: String
    var paneID: String
    var name: String?
    var index: Int
    var focused: Bool
    var contentKind: String
    var contentID: String
}

struct CloudVMTerminalState: Hashable, Codable, Sendable {
    var id: String
    var tabIDs: [String]
    var title: String
    var cwd: String?
    var lifecycle: String
    var cols: Int?
    var rows: Int?
    var running: Bool?
}

struct CloudVMBrowserState: Hashable, Codable, Sendable {
    var id: String
    var tabID: String
    var url: String
    var title: String
    var status: String
}

struct CloudVMAgentState: Hashable, Codable, Sendable {
    var id: String?
    var terminalID: String
    var state: String
    var source: String?
}

/// Complete state for one remote cmux-tui session.
///
/// `rawSnapshot` preserves fields that this app does not understand yet. The
/// typed graph is derived from the same bytes and is never updated independently.
/// This gives the agent a stable graph today and an accretive escape hatch for new
/// daemon resources tomorrow.
struct CloudVMState: Hashable, Codable, Sendable {
    var machine: SurfaceMachineID
    var cursor: CloudVMCursor
    var rawSnapshot: Data
    var workspaces: [CloudVMWorkspaceState]
    var screens: [CloudVMScreenState]
    var panes: [CloudVMPaneState]
    var tabs: [CloudVMTabState]
    var terminals: [CloudVMTerminalState]
    var browsers: [CloudVMBrowserState]
    var agents: [CloudVMAgentState]
    var otherEntities: [CloudVMEntity]

    var workspaceIDs: Set<String> { Set(workspaces.map(\.id)) }

    func entity(kind: String, id: String) -> CloudVMEntity? {
        entities(kind: kind).first { $0.id == id }
    }

    /// Unified read access for agents and future features. Known typed kinds
    /// and opaque kinds use the same plural snapshot-key vocabulary; singular
    /// daemon resource names are accepted as aliases.
    func entities(kind: String) -> [CloudVMEntity] {
        let key = Self.snapshotKey(for: kind)
        guard key != "cursor" else { return [] }
        guard let snapshot = snapshotObject(), let value = snapshot[key] else {
            return otherEntities.filter { $0.kind == kind }
        }
        let objects: [[String: Any]]
        if let object = value as? [String: Any] {
            objects = [object]
        } else if let array = value as? [[String: Any]] {
            objects = array
        } else {
            return []
        }
        return objects.compactMap { object in
            guard let payload = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
                return nil
            }
            return CloudVMEntity(kind: key, id: object["id"] as? String, payload: payload)
        }
    }

    func snapshotObject() -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: rawSnapshot) as? [String: Any]
    }

    private static func snapshotKey(for kind: String) -> String {
        switch kind {
        case "machine", "machines": return "machine"
        case "session", "sessions": return "session"
        case "workspace", "workspaces": return "workspaces"
        case "screen", "screens": return "screens"
        case "pane", "panes": return "panes"
        case "tab", "tabs": return "tabs"
        case "terminal", "terminals": return "terminals"
        case "browser", "browsers": return "browsers"
        case "client", "clients": return "clients"
        case "notification", "notifications": return "notifications"
        case "agent", "agents": return "agents"
        case "pairing_request", "pairing_requests": return "pairing_requests"
        case "frontend_projection", "frontend_projections": return "frontend_projections"
        case "sidebar_view", "sidebar_views": return "sidebar_views"
        default: return kind
        }
    }

    /// Returns the complete document for an agent read, with credential-like
    /// fields redacted. Synchronization still uses rawSnapshot; this boundary
    /// only protects the local control socket from leaking pairing or renderer
    /// secrets.
    func agentSnapshotObject() -> [String: Any]? {
        guard let snapshot = snapshotObject() else { return nil }
        return Self.redact(snapshot, context: []) as? [String: Any]
    }

    func agentEntityObject(_ entity: CloudVMEntity) -> Any {
        guard let object = try? JSONSerialization.jsonObject(with: entity.payload) else {
            return NSNull()
        }
        return Self.redact(object, context: [entity.kind])
    }

    private static func redact(_ value: Any, context: [String]) -> Any {
        if let dictionary = value as? [String: Any] {
            var result: [String: Any] = [:]
            for (childKey, childValue) in dictionary {
                if isSensitiveKey(childKey, context: context) {
                    result[childKey] = "[REDACTED]"
                } else {
                    result[childKey] = redact(childValue, context: context + [childKey])
                }
            }
            return result
        }
        if let array = value as? [Any] {
            return array.map { redact($0, context: context) }
        }
        return value
    }

    private static func isSensitiveKey(_ key: String, context: [String]) -> Bool {
        let normalized = key
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
        if normalized == "code", context.contains("pairing_requests") {
            return true
        }
        let exact = Set([
            "token", "secret", "password", "credential", "private_key",
            "authorization", "access_key", "client_secret"
        ])
        return exact.contains(normalized)
            || normalized.hasSuffix("_token")
            || normalized.hasSuffix("_secret")
            || normalized.hasSuffix("_password")
            || normalized.hasSuffix("_credential")
            || normalized.hasSuffix("_private_key")
    }
}

/// Freshness of an accepted document is separate from the document itself.
/// A sleeping or disconnected VM can still have useful last-known state, but
/// that state must never be mistaken for a permission to mutate the VM.
enum CloudVMStateFreshness: String, Codable, Sendable {
    case current
    case stale
}

struct CloudVMStateObservation: Hashable, Codable, Sendable {
    var freshness: CloudVMStateFreshness
    var reason: String?

    static let current = CloudVMStateObservation(freshness: .current, reason: nil)

    static func stale(reason: String? = nil) -> Self {
        Self(freshness: .stale, reason: reason)
    }
}

/// The stream can carry a delta that the desktop does not understand, or it can
/// end because its journal window overflowed. Both cases require a new snapshot.
enum CloudVMStateSyncDecision: Equatable, Sendable {
    case ignoreStale
    case installSnapshot
    case fetchSnapshot

    /// Decide whether one stream item can advance the installed graph.
    ///
    /// A revision has meaning only inside its generation. A new generation is a
    /// new daemon session and therefore accepts a snapshot even when its numeric
    /// revision is lower. A delta must join the exact cursor already installed;
    /// accepting a non-contiguous delta would silently lose an entity update.
    static func forSnapshot(
        incoming: CloudVMCursor,
        current: CloudVMCursor?
    ) -> Self {
        guard let current else { return .installSnapshot }
        guard incoming.generation == current.generation else { return .installSnapshot }
        return incoming.revision > current.revision ? .installSnapshot : .ignoreStale
    }

    static func forDelta(
        generation: String,
        previousRevision: UInt64,
        revision: UInt64,
        current: CloudVMCursor?
    ) -> Self {
        guard let current,
              generation == current.generation else { return .fetchSnapshot }
        guard revision > current.revision else { return .ignoreStale }
        guard previousRevision == current.revision else { return .fetchSnapshot }
        return .installSnapshot
    }
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
    /// Exact graph coordinates. They make a local pane's rename target stable even
    /// when the same terminal is present in several workspaces.
    var screenID: String? = nil
    var paneID: String? = nil
    var name: String? = nil
    var index: Int? = nil
    var focused: Bool? = nil
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
    /// The remote placement represented by this local pane, if it came from a
    /// cloud graph. A terminal id alone is not enough because tab names are
    /// placement-local.
    var remoteWorkspaceID: String? = nil
    var remoteTabID: String? = nil
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
    /// The machine's address on its owner's private network (v4 preferred),
    /// reachable through the WireGuard tunnel. nil for the local Mac and for
    /// machines created before private networking.
    var privateAddress: String? = nil
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

/// One atomic export for agent and socket readers. The sidebar consumes only
/// `catalog`; the complete daemon graphs stay out of its high-frequency value.
/// Both halves are captured in the same main-actor turn, so their cursors and
/// derived resource rows always describe one accepted state.
struct SurfaceCatalogExport: Sendable {
    var catalog: SurfaceCatalogSnapshot
    var cloudStates: [CloudVMState]
    /// Observation metadata is kept beside, not inside, the daemon document.
    /// This preserves cursor/raw-snapshot equality while making offline state
    /// explicit to agents.
    var cloudStateObservations: [SurfaceMachineID: CloudVMStateObservation] = [:]
}

/// Persisted with the session: which resource each pane projected, so a restored pane
/// re-projects a remote resource instead of becoming an anonymous shell.
struct SurfaceProjectionRecord: Hashable, Codable, Sendable {
    var panelID: UUID
    var resource: SurfaceResourceID
    var remoteWorkspaceID: String? = nil
    var remoteTabID: String? = nil
}

enum SurfaceCatalogError: Error, LocalizedError, Equatable {
    case unknownResource(SurfaceResourceID)
    case noProvider(SurfaceMachineID)
    case unavailable(SurfaceResourceID, reason: String)
    case ambiguousRemotePlacement(SurfaceResourceID, workspaceID: String)
    case destinationNotFound(String)
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case .unknownResource(let id): return "Unknown surface \(id)."
        case .noProvider(let machine): return "No provider for machine \(machine)."
        case .unavailable(let id, let reason): return "\(id) is unavailable: \(reason)"
        case .ambiguousRemotePlacement(let id, let workspaceID):
            return "\(id) has more than one tab in remote workspace \(workspaceID); provide the tab id."
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
