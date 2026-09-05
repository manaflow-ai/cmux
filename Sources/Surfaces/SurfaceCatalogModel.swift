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

/// The two valid remote tab-label states. The daemon uses an empty string to
/// clear its optional label, so keep that state explicit at the app boundary
/// instead of making every caller rediscover the trim-and-clear rule.
enum CloudRemoteRenameName: Hashable, Sendable {
    case named(String)
    case cleared

    init(rawValue: String) {
        let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        self = normalized.isEmpty ? .cleared : .named(normalized)
    }

    /// The exact value passed to `tab … rename --name`.
    var wireValue: String {
        switch self {
        case .named(let value): return value
        case .cleared: return ""
        }
    }

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

/// How a remote session can be synchronized.
///
/// Current cmux-tui daemons publish a generation and revision, so the desktop can
/// apply contiguous deltas and fence mutations with compare-and-swap. Older
/// daemons publish the same graph without a cursor. Their snapshot is still useful
/// for display and inspection, but it cannot prove ordering or authorize a
/// revision-fenced mutation.
enum CloudVMStateSyncMode: String, Codable, Sendable {
    case journaled
    case snapshotOnly = "snapshot_only"
}

/// The join key for a tab's content. A terminal and a browser may use the same
/// daemon-local id, so the content kind is part of the identity.
struct CloudVMTabContentKey: Hashable, Sendable {
    var kind: String
    var id: String
}

/// Materialized joins for one accepted daemon graph. The arrays on
/// `CloudVMState` remain the ordered, agent-facing representation. This value is
/// a derived lookup layer, rebuilt once at a snapshot boundary and changed only
/// for entities named by a delta. It is deliberately not encoded: a cache must
/// never become a second persisted source of truth.
struct CloudVMStateIndex: Sendable {
    var workspacesByID: [String: CloudVMWorkspaceState] = [:]
    var screensByID: [String: CloudVMScreenState] = [:]
    var panesByID: [String: CloudVMPaneState] = [:]
    var tabsByID: [String: CloudVMTabState] = [:]
    var terminalsByID: [String: CloudVMTerminalState] = [:]
    var browsersByID: [String: CloudVMBrowserState] = [:]
    var agentsByID: [String: CloudVMAgentState] = [:]
    var agentsByTerminalID: [String: CloudVMAgentState] = [:]
    var screenIDsByWorkspaceID: [String: [String]] = [:]
    var paneIDsByScreenID: [String: [String]] = [:]
    var tabIDsByPaneID: [String: [String]] = [:]
    var tabIDsByContent: [CloudVMTabContentKey: [String]] = [:]

    init(
        workspaces: [CloudVMWorkspaceState],
        screens: [CloudVMScreenState],
        panes: [CloudVMPaneState],
        tabs: [CloudVMTabState],
        terminals: [CloudVMTerminalState],
        browsers: [CloudVMBrowserState],
        agents: [CloudVMAgentState]
    ) {
        for workspace in workspaces {
            workspacesByID[workspace.id] = workspace
        }
        for screen in screens {
            screensByID[screen.id] = screen
            append(screen.id, to: &screenIDsByWorkspaceID, keyedBy: screen.workspaceID)
        }
        for pane in panes {
            panesByID[pane.id] = pane
            append(pane.id, to: &paneIDsByScreenID, keyedBy: pane.screenID)
        }
        for tab in tabs {
            insertTab(tab)
        }
        for terminal in terminals {
            terminalsByID[terminal.id] = terminal
        }
        for browser in browsers {
            browsersByID[browser.id] = browser
        }
        for agent in agents {
            insertAgent(agent)
        }
    }

    func workspace(id: String) -> CloudVMWorkspaceState? {
        workspacesByID[id]
    }

    func screen(id: String) -> CloudVMScreenState? {
        screensByID[id]
    }

    func pane(id: String) -> CloudVMPaneState? {
        panesByID[id]
    }

    func tab(id: String) -> CloudVMTabState? {
        tabsByID[id]
    }

    func terminal(id: String) -> CloudVMTerminalState? {
        terminalsByID[id]
    }

    func browser(id: String) -> CloudVMBrowserState? {
        browsersByID[id]
    }

    func agent(id: String) -> CloudVMAgentState? {
        agentsByID[id]
    }

    func agent(terminalID: String) -> CloudVMAgentState? {
        agentsByTerminalID[terminalID]
    }

    func screenIDs(workspaceID: String) -> [String] {
        orderedIDs(
            screenIDsByWorkspaceID[workspaceID] ?? [],
            index: { screensByID[$0]?.index }
        )
    }

    func paneIDs(screenID: String) -> [String] {
        paneIDsByScreenID[screenID] ?? []
    }

    func tabIDs(paneID: String) -> [String] {
        orderedTabIDs(tabIDsByPaneID[paneID] ?? [])
    }

    func tabs(contentKind: String, contentID: String) -> [CloudVMTabState] {
        let key = CloudVMTabContentKey(kind: contentKind, id: contentID)
        return orderedTabIDs(tabIDsByContent[key] ?? []).compactMap { tabsByID[$0] }
    }

    private func orderedTabIDs(_ ids: [String]) -> [String] {
        orderedIDs(ids, index: { tabsByID[$0]?.index })
    }

    /// Relationship indexes are append-only caches, so their order must be
    /// rebuilt from the entity's explicit semantic index whenever a caller
    /// reads it. Transport arrival order is only the fallback for legacy rows
    /// that do not carry an index.
    private func orderedIDs(_ ids: [String], index: (String) -> Int?) -> [String] {
        ids.enumerated().sorted { left, right in
            let leftIndex = index(left.element)
            let rightIndex = index(right.element)
            switch (leftIndex, rightIndex) {
            case let (left?, right?) where left != right:
                return left < right
            case (.some, .none):
                return true
            case (.none, .some):
                return false
            default:
                return left.offset < right.offset
            }
        }.map { $0.element }
    }

    mutating func upsertWorkspace(_ workspace: CloudVMWorkspaceState) {
        workspacesByID[workspace.id] = workspace
    }

    mutating func removeWorkspace(id: String) {
        workspacesByID.removeValue(forKey: id)
    }

    mutating func upsertScreen(_ screen: CloudVMScreenState) {
        if let old = screensByID[screen.id], old.workspaceID != screen.workspaceID {
            remove(screen.id, from: &screenIDsByWorkspaceID, keyedBy: old.workspaceID)
        }
        screensByID[screen.id] = screen
        appendUnique(screen.id, to: &screenIDsByWorkspaceID, keyedBy: screen.workspaceID)
    }

    mutating func removeScreen(id: String) {
        guard let old = screensByID.removeValue(forKey: id) else { return }
        remove(id, from: &screenIDsByWorkspaceID, keyedBy: old.workspaceID)
    }

    mutating func upsertPane(_ pane: CloudVMPaneState) {
        if let old = panesByID[pane.id], old.screenID != pane.screenID {
            remove(pane.id, from: &paneIDsByScreenID, keyedBy: old.screenID)
        }
        panesByID[pane.id] = pane
        appendUnique(pane.id, to: &paneIDsByScreenID, keyedBy: pane.screenID)
    }

    mutating func setPaneTabIDs(_ tabIDs: [String], paneID: String) {
        guard var pane = panesByID[paneID] else { return }
        pane.tabIDs = tabIDs
        panesByID[paneID] = pane
    }

    mutating func removePane(id: String) {
        guard let old = panesByID.removeValue(forKey: id) else { return }
        remove(id, from: &paneIDsByScreenID, keyedBy: old.screenID)
    }

    mutating func upsertTab(_ tab: CloudVMTabState) {
        if let old = tabsByID[tab.id] {
            removeTabReferences(old)
        }
        tabsByID[tab.id] = tab
        insertTabReferences(tab)
    }

    mutating func removeTab(id: String) {
        guard let old = tabsByID.removeValue(forKey: id) else { return }
        removeTabReferences(old)
    }

    mutating func upsertTerminal(_ terminal: CloudVMTerminalState) {
        terminalsByID[terminal.id] = terminal
    }

    mutating func removeTerminal(id: String) {
        terminalsByID.removeValue(forKey: id)
    }

    mutating func upsertBrowser(_ browser: CloudVMBrowserState) {
        browsersByID[browser.id] = browser
    }

    mutating func removeBrowser(id: String) {
        browsersByID.removeValue(forKey: id)
    }

    mutating func upsertAgent(_ agent: CloudVMAgentState) {
        if let old = agentsByTerminalID[agent.terminalID] {
            removeAgent(old)
        }
        if let id = agent.id, let old = agentsByID[id] {
            removeAgent(old)
        }
        insertAgent(agent)
    }

    mutating func removeAgent(_ agent: CloudVMAgentState) {
        if agentsByTerminalID[agent.terminalID]?.id == agent.id {
            agentsByTerminalID.removeValue(forKey: agent.terminalID)
        }
        if let id = agent.id, agentsByID[id]?.terminalID == agent.terminalID {
            agentsByID.removeValue(forKey: id)
        }
    }

    private mutating func insertAgent(_ agent: CloudVMAgentState) {
        agentsByTerminalID[agent.terminalID] = agent
        if let id = agent.id {
            agentsByID[id] = agent
        }
    }

    private mutating func insertTab(_ tab: CloudVMTabState) {
        tabsByID[tab.id] = tab
        insertTabReferences(tab)
    }

    private mutating func insertTabReferences(_ tab: CloudVMTabState) {
        appendUnique(tab.id, to: &tabIDsByPaneID, keyedBy: tab.paneID)
        appendUnique(
            tab.id,
            to: &tabIDsByContent,
            keyedBy: CloudVMTabContentKey(kind: tab.contentKind, id: tab.contentID)
        )
    }

    private mutating func removeTabReferences(_ tab: CloudVMTabState) {
        remove(tab.id, from: &tabIDsByPaneID, keyedBy: tab.paneID)
        remove(
            tab.id,
            from: &tabIDsByContent,
            keyedBy: CloudVMTabContentKey(kind: tab.contentKind, id: tab.contentID)
        )
    }

    private func append<Value: Hashable>(_ value: Value, to map: inout [String: [Value]], keyedBy key: String) {
        map[key, default: []].append(value)
    }

    private func appendUnique<Value: Hashable>(_ value: Value, to map: inout [String: [Value]], keyedBy key: String) {
        if !map[key, default: []].contains(value) {
            map[key, default: []].append(value)
        }
    }

    private func appendUnique<Value: Hashable, Key: Hashable>(
        _ value: Value,
        to map: inout [Key: [Value]],
        keyedBy key: Key
    ) {
        if !map[key, default: []].contains(value) {
            map[key, default: []].append(value)
        }
    }

    private func remove<Value: Equatable>(_ value: Value, from map: inout [String: [Value]], keyedBy key: String) {
        guard var values = map[key] else { return }
        values.removeAll { $0 == value }
        if values.isEmpty {
            map.removeValue(forKey: key)
        } else {
            map[key] = values
        }
    }

    private func remove<Value: Equatable, Key: Hashable>(
        _ value: Value,
        from map: inout [Key: [Value]],
        keyedBy key: Key
    ) {
        guard var values = map[key] else { return }
        values.removeAll { $0 == value }
        if values.isEmpty {
            map.removeValue(forKey: key)
        } else {
            map[key] = values
        }
    }
}

/// One top-level JSON array kept as individually addressable canonical row bytes.
/// `order` preserves the snapshot or storage order for lossless round trips. It
/// is not semantic placement order after deltas. Consumers must use each row's
/// explicit index and relationship fields for placement. Rows without an id use
/// a private positional key so unknown future fields remain lossless.
///
/// The identity index is derived and deliberately not encoded. Snapshot import
/// pays O(rows) to build it, then delta identity resolution is O(1) for daemon
/// identity fields (`id` and the legacy agent `terminal_id`). This keeps the
/// canonical document as the only source of truth without making every rename
/// scan and decode the whole collection. An unsupported compatibility field
/// uses a bounded fallback scan so this internal API remains correct for future
/// callers without pretending that arbitrary payload fields are identities.
struct CloudVMRawCollection: Hashable, Codable, Sendable {
    private struct IdentityKey: Hashable, Sendable {
        let field: String
        let value: String
    }

    private static let indexedIdentityFields: Set<String> = ["id", "terminal_id"]

    private(set) var order: [String] = []
    private(set) var rows: [String: Data] = [:]
    private var identityIndex: [IdentityKey: [String]] = [:]

    init() {}

    init(order: [String], rows: [String: Data]) {
        self.order = order
        self.rows = rows
        rebuildIdentityIndex()
    }

    /// Returns row keys for a stable identity. The direct storage key is also
    /// considered because a legacy row can acquire an explicit payload id while
    /// retaining its positional key.
    func matchingRowIDs(
        id: String,
        alternateField: (name: String, value: String)? = nil
    ) -> [String] {
        var matches: [String] = []
        var seen = Set<String>()
        appendUniqueIfPresent(id, to: &matches, seen: &seen)
        appendUnique(indexedRowIDs(field: "id", value: id), to: &matches, seen: &seen)
        if let alternateField {
            if let indexed = indexedRowIDsIfSupported(field: alternateField.name, value: alternateField.value) {
                appendUnique(indexed, to: &matches, seen: &seen)
            } else {
                // Preserve the generic alternate-field contract for future
                // compatibility callers. Current daemon deltas use the indexed
                // `terminal_id` path and do not enter this fallback.
                appendUnique(
                    scannedRowIDs(field: alternateField.name, value: alternateField.value),
                    to: &matches,
                    seen: &seen
                )
            }
        }
        return matches
    }

    func object(forRowID rowID: String) -> [String: Any]? {
        guard let data = rows[rowID] else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? [String: Any]
    }

    mutating func insertRow(rowID: String, data: Data, object: [String: Any]) {
        order.append(rowID)
        rows[rowID] = data
        addIdentityEntries(for: rowID, object: object)
    }

    mutating func replaceRow(rowID: String, data: Data, object: [String: Any]) {
        removeIdentityEntries(for: rowID)
        rows[rowID] = data
        addIdentityEntries(for: rowID, object: object)
    }

    mutating func removeRow(rowID: String, object: [String: Any]) {
        removeIdentityEntries(for: rowID, object: object)
        rows.removeValue(forKey: rowID)
        order.removeAll { $0 == rowID }
    }

    private func appendUniqueIfPresent(_ rowID: String, to matches: inout [String], seen: inout Set<String>) {
        guard rows[rowID] != nil, seen.insert(rowID).inserted else { return }
        matches.append(rowID)
    }

    private func appendUnique(_ rowIDs: [String], to matches: inout [String], seen: inout Set<String>) {
        for rowID in rowIDs where rows[rowID] != nil && seen.insert(rowID).inserted {
            matches.append(rowID)
        }
    }

    private func indexedRowIDs(field: String, value: String) -> [String] {
        indexedRowIDsIfSupported(field: field, value: value) ?? []
    }

    private func indexedRowIDsIfSupported(field: String, value: String) -> [String]? {
        guard Self.indexedIdentityFields.contains(field),
              let normalized = Self.nonEmptyString(value) else { return nil }
        return identityIndex[IdentityKey(field: field, value: normalized)] ?? []
    }

    private func scannedRowIDs(field: String, value: String) -> [String] {
        guard let normalized = Self.nonEmptyString(value) else { return [] }
        return order.compactMap { rowID in
            guard let object = object(forRowID: rowID),
                  Self.nonEmptyString(object[field]) == normalized else { return nil }
            return rowID
        }
    }

    private mutating func rebuildIdentityIndex() {
        identityIndex.removeAll(keepingCapacity: true)
        for rowID in order {
            guard let object = object(forRowID: rowID) else { continue }
            addIdentityEntries(for: rowID, object: object)
        }
    }

    private mutating func addIdentityEntries(for rowID: String, object: [String: Any]) {
        for field in Self.indexedIdentityFields {
            guard let value = Self.nonEmptyString(object[field]) else { continue }
            let key = IdentityKey(field: field, value: value)
            if !identityIndex[key, default: []].contains(rowID) {
                identityIndex[key, default: []].append(rowID)
            }
        }
    }

    private mutating func removeIdentityEntries(for rowID: String, object: [String: Any]? = nil) {
        let resolvedObject = object ?? self.object(forRowID: rowID)
        for field in Self.indexedIdentityFields {
            guard let value = resolvedObject.flatMap({ Self.nonEmptyString($0[field]) }) else { continue }
            let key = IdentityKey(field: field, value: value)
            guard var rowIDs = identityIndex[key] else { continue }
            rowIDs.removeAll { $0 == rowID }
            if rowIDs.isEmpty {
                identityIndex.removeValue(forKey: key)
            } else {
                identityIndex[key] = rowIDs
            }
        }
    }

    private static func nonEmptyString(_ raw: Any?) -> String? {
        guard let value = raw as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private enum CodingKeys: String, CodingKey {
        case order, rows
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        order = try container.decodeIfPresent([String].self, forKey: .order) ?? []
        rows = try container.decodeIfPresent([String: Data].self, forKey: .rows) ?? [:]
        identityIndex = [:]
        rebuildIdentityIndex()
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(order, forKey: .order)
        try container.encode(rows, forKey: .rows)
    }

    static func == (lhs: CloudVMRawCollection, rhs: CloudVMRawCollection) -> Bool {
        lhs.order == rhs.order && lhs.rows == rhs.rows
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(order)
        hasher.combine(rows)
    }
}

/// Fragmented canonical representation of one daemon snapshot. Known and
/// unknown top-level values share this document. Updating one row never parses
/// or re-encodes unrelated rows; `object()` and `data()` are deliberate export
/// boundaries that materialize the complete JSON document.
struct CloudVMStateDocument: Hashable, Codable, Sendable {
    private(set) var values: [String: Data] = [:]
    private(set) var collections: [String: CloudVMRawCollection] = [:]
    private var canonicalDataCache: Data?

    init(snapshot: [String: Any]) {
        for (key, value) in snapshot {
            if let rows = value as? [[String: Any]] {
                var collection = CloudVMRawCollection()
                var valid = true
                for (offset, row) in rows.enumerated() {
                    guard let data = Self.canonicalData(row) else {
                        valid = false
                        break
                    }
                    let baseID = Self.nonEmptyString(row["id"])
                    let rowID = Self.uniqueRowKey(baseID ?? "__row_\(offset)", in: collection.rows)
                    collection.insertRow(rowID: rowID, data: data, object: row)
                }
                if valid {
                    collections[key] = collection
                } else if let data = Self.canonicalData(value) {
                    // Retain an unexpected mixed array as one opaque value. A
                    // partial collection would silently discard daemon state.
                    values[key] = data
                }
            } else if let data = Self.canonicalData(value) {
                values[key] = data
            }
        }
        canonicalDataCache = Self.canonicalData(snapshot)
    }

    init?(data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        self.init(snapshot: object)
        // The input may be valid JSON with a different key order or whitespace.
        // Store only the canonical form so equality, export, and delta updates
        // have one stable byte representation.
        guard let canonical = Self.canonicalData(object) else { return nil }
        canonicalDataCache = canonical
    }

    /// Materializes the complete document for export or recovery only.
    func data() -> Data? {
        if let canonicalDataCache { return canonicalDataCache }
        return Self.canonicalData(object())
    }

    /// Materializes Foundation values for legacy parser and agent export paths.
    func object() -> [String: Any]? {
        var result: [String: Any] = [:]
        for (key, data) in values {
            guard let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return nil }
            result[key] = value
        }
        for (key, collection) in collections {
            var rows: [Any] = []
            rows.reserveCapacity(collection.order.count)
            for rowID in collection.order {
                guard let data = collection.rows[rowID],
                      let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return nil }
                rows.append(value)
            }
            result[key] = rows
        }
        return result
    }

    /// Decodes one top-level value without materializing unrelated collections.
    func value(forKey key: String) -> Any? {
        guard let data = values[key] else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    /// Decodes one collection's rows without materializing the complete graph.
    /// The result follows the stable snapshot or storage order recorded in
    /// `CloudVMRawCollection.order`. Semantic placement comes from row fields.
    func objects(forCollectionKey key: String) -> [[String: Any]]? {
        guard let collection = collections[key] else { return nil }
        var result: [[String: Any]] = []
        result.reserveCapacity(collection.order.count)
        for rowID in collection.order {
            guard let data = collection.rows[rowID],
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return nil }
            result.append(object)
        }
        return result
    }

    /// A delta may update only collections that were present in the accepted
    /// snapshot. Creating a new collection from a delta would turn an omitted
    /// collection into an apparently authoritative empty or partial graph.
    func containsCollection(_ key: String) -> Bool {
        collections[key] != nil
    }

    /// Whether this key is present as either a scalar fragment or a collection.
    /// Callers use this to distinguish a missing future resource from a present
    /// resource whose requested identity is ambiguous or absent.
    func containsFragment(_ key: String) -> Bool {
        values[key] != nil || collections[key] != nil
    }

    /// Resolves one entity directly from its canonical fragment. A duplicate
    /// identity returns nil instead of selecting the first row, so an agent can
    /// request a fresh authoritative snapshot rather than mutate an arbitrary
    /// remote object.
    func entity(forCollectionKey key: String, id: String) -> CloudVMEntity? {
        let normalizedID = Self.nonEmptyString(id)
        if let collection = collections[key], let normalizedID {
            let candidates = collection.matchingRowIDs(id: normalizedID)
            guard candidates.count == 1, let rowID = candidates.first,
                  let data = collection.rows[rowID] else { return nil }
            return CloudVMEntity(kind: key, id: Self.entityID(from: data), payload: data)
        }
        guard let data = values[key],
              let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? [String: Any],
              normalizedID != nil,
              Self.nonEmptyString(object["id"]) == normalizedID else { return nil }
        return CloudVMEntity(kind: key, id: Self.entityID(from: data), payload: data)
    }

    /// Returns opaque entities directly from the canonical fragments. This is
    /// an export projection, not another mutable copy of the remote graph.
    /// Scalar values are retained too, so a future daemon field is never lost
    /// only because this client does not know its shape yet.
    func opaqueEntities(excluding excludedKeys: Set<String>) -> [CloudVMEntity] {
        var result: [CloudVMEntity] = []
        for (key, data) in values where !excludedKeys.contains(key) {
            result.append(CloudVMEntity(kind: key, id: Self.entityID(from: data), payload: data))
        }
        for (key, collection) in collections where !excludedKeys.contains(key) {
            for rowID in collection.order {
                guard let data = collection.rows[rowID] else { continue }
                result.append(CloudVMEntity(kind: key, id: Self.entityID(from: data), payload: data))
            }
        }
        return result.sorted {
            if $0.kind != $1.kind { return $0.kind < $1.kind }
            let leftID = $0.id ?? ""
            let rightID = $1.id ?? ""
            if leftID != rightID { return leftID < rightID }
            return $0.payload.lexicographicallyPrecedes($1.payload)
        }
    }

    @discardableResult
    mutating func setCursor(_ cursor: CloudVMCursor) -> Bool {
        // Keep cursor extensions emitted by a newer daemon. The generation and
        // revision are the fields this client owns; every other field remains
        // lossless across a local delta.
        var cursorObject: [String: Any] = [:]
        if let existing = values["cursor"],
           let decoded = try? JSONSerialization.jsonObject(with: existing) as? [String: Any] {
            cursorObject = decoded
        }
        cursorObject["generation"] = cursor.generation
        cursorObject["revision"] = String(cursor.revision)
        guard let data = Self.canonicalData(cursorObject) else { return false }
        values["cursor"] = data
        collections.removeValue(forKey: "cursor")
        canonicalDataCache = nil
        return true
    }

    /// Replaces one collection row. `alternateField` supports legacy rows whose
    /// stable identity is a relationship (currently agents use terminal_id).
    /// An existing explicit id is preserved when a legacy update omits it.
    mutating func upsert(
        collectionKey: String,
        id: String,
        value: [String: Any],
        alternateField: (name: String, value: String)? = nil
    ) -> Bool {
        guard let rowData = Self.canonicalData(value) else { return false }
        var collection = collections[collectionKey] ?? CloudVMRawCollection()
        let explicitID = Self.nonEmptyString(value["id"])
        guard explicitID == nil || explicitID == id else { return false }
        // The collection index handles both explicit and positional storage
        // keys. Duplicate identities remain visible as multiple matches and
        // therefore force snapshot recovery below.
        let uniqueMatches = collection.matchingRowIDs(id: id, alternateField: alternateField)
        guard uniqueMatches.count <= 1 else { return false }
        let rowID = uniqueMatches.first
        let existingObject = rowID.flatMap { collection.object(forRowID: $0) }
        if let rowID,
           let existingID = existingObject.flatMap({ Self.nonEmptyString($0["id"]) }),
           let explicitID,
           existingID != explicitID {
            // An explicit identity cannot silently claim a different row found
            // through a compatibility relationship. Force a fresh snapshot so
            // the daemon can state whether this is a replacement or a new row.
            return false
        }
        var storedData = rowData
        if let rowID,
           explicitID == nil,
           let existingID = existingObject.flatMap({ Self.nonEmptyString($0["id"]) }) {
            var merged = value
            merged["id"] = existingID
            guard let mergedData = Self.canonicalData(merged) else { return false }
            storedData = mergedData
            collection.replaceRow(rowID: rowID, data: storedData, object: merged)
        } else if let rowID {
            collection.replaceRow(rowID: rowID, data: storedData, object: value)
        } else {
            let newID = Self.uniqueRowKey(id, in: collection.rows)
            collection.insertRow(rowID: newID, data: storedData, object: value)
        }
        // Commit the collection replacement only after every identity and
        // serialization guard has passed. A failed delta must leave the
        // document byte-for-byte unchanged so callers can safely retry from a
        // fresh snapshot.
        values.removeValue(forKey: collectionKey)
        collections[collectionKey] = collection
        canonicalDataCache = nil
        return true
    }

    mutating func delete(
        collectionKey: String,
        id: String,
        alternateField: (name: String, value: String)? = nil
    ) -> Bool {
        guard var collection = collections[collectionKey] else { return false }
        let uniqueMatches = collection.matchingRowIDs(id: id, alternateField: alternateField)
        guard uniqueMatches.count == 1,
              let rowID = uniqueMatches.first,
              let rowObject = collection.object(forRowID: rowID)
        else { return false }
        // A relationship fallback is valid only for an id-less legacy row or
        // the exact requested identity. If a stale relationship points at a
        // different explicit row, force snapshot recovery instead of deleting
        // the wrong terminal or tab.
        if let existingID = Self.nonEmptyString(rowObject["id"]), existingID != id {
            return false
        }
        if let alternateField,
           Self.nonEmptyString(rowObject[alternateField.name]) != alternateField.value {
            // An explicit id and a relationship are a compound identity
            // contract for compatibility deletes. A missing or stale
            // relationship must not authorize removal of an otherwise matching
            // row.
            return false
        }
        collection.removeRow(rowID: rowID, object: rowObject)
        collections[collectionKey] = collection
        canonicalDataCache = nil
        return true
    }

    mutating func replaceSingleton(key: String, value: [String: Any]) -> Bool {
        guard let data = Self.canonicalData(value) else { return false }
        values[key] = data
        collections.removeValue(forKey: key)
        canonicalDataCache = nil
        return true
    }

    mutating func removeSingleton(key: String, id: String) -> Bool {
        guard let data = values[key],
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Self.nonEmptyString(object["id"]) == id else { return false }
        values.removeValue(forKey: key)
        collections.removeValue(forKey: key)
        canonicalDataCache = nil
        return true
    }

    private static func uniqueRowKey(_ base: String, in rows: [String: Data]) -> String {
        guard rows[base] != nil else { return base }
        var suffix = 1
        while rows["\(base)#\(suffix)"] != nil { suffix += 1 }
        return "\(base)#\(suffix)"
    }

    private static func nonEmptyString(_ raw: Any?) -> String? {
        guard let value = raw as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func entityID(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? [String: Any]
        else { return nil }
        return nonEmptyString(object["id"])
    }

    private static func canonicalData(_ object: Any?) -> Data? {
        guard let object else { return nil }
        return try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .fragmentsAllowed])
    }

    private enum CodingKeys: String, CodingKey {
        case values, collections
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        values = try container.decodeIfPresent([String: Data].self, forKey: .values) ?? [:]
        collections = try container.decodeIfPresent([String: CloudVMRawCollection].self, forKey: .collections) ?? [:]
        canonicalDataCache = nil
        guard values.keys.allSatisfy({ !collections.keys.contains($0) }),
              collections.values.allSatisfy(Self.isValidCollection),
              values.values.allSatisfy(Self.isValidJSONData)
        else {
            throw DecodingError.dataCorruptedError(
                forKey: .collections,
                in: container,
                debugDescription: "CloudVMStateDocument contains an invalid or colliding fragment"
            )
        }
    }

    private static func isValidCollection(_ collection: CloudVMRawCollection) -> Bool {
        let order = Set(collection.order)
        guard order.count == collection.order.count,
              order.count == collection.rows.count,
              order.allSatisfy({ collection.rows[$0] != nil })
        else { return false }
        return collection.rows.values.allSatisfy(Self.isValidJSONData)
    }

    private static func isValidJSONData(_ data: Data) -> Bool {
        (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) != nil
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(values, forKey: .values)
        try container.encode(collections, forKey: .collections)
    }

    static func == (lhs: CloudVMStateDocument, rhs: CloudVMStateDocument) -> Bool {
        lhs.values == rhs.values && lhs.collections == rhs.collections
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(values)
        hasher.combine(collections)
    }
}

/// Complete state for one remote cmux-tui session.
///
/// `document` preserves fields that this app does not understand yet. The typed
/// graph and lookup index are derived from that same document and are never
/// independent write sources. This gives the agent a stable graph today and an
/// accretive escape hatch for new daemon resources tomorrow. A nil cursor is an
/// explicit legacy snapshot-only mode, not an invalid or partially parsed graph.
struct CloudVMState: Hashable, Codable, Sendable {
    private static let modeledSnapshotKeys: Set<String> = [
        "machine", "session", "cursor",
        "workspaces", "screens", "panes", "tabs", "terminals", "browsers", "agents",
    ]

    var machine: SurfaceMachineID
    var cursor: CloudVMCursor?
    /// The canonical document owns both known and unknown remote fields. The
    /// byte form is materialized only when a caller crosses an export boundary.
    var document: CloudVMStateDocument
    var workspaces: [CloudVMWorkspaceState]
    var screens: [CloudVMScreenState]
    var panes: [CloudVMPaneState]
    var tabs: [CloudVMTabState]
    var terminals: [CloudVMTerminalState]
    var browsers: [CloudVMBrowserState]
    var agents: [CloudVMAgentState]
    /// Derived joins are rebuilt at snapshot boundaries and updated transactionally
    /// with accepted deltas. They are excluded from Codable below.
    var lookupIndex: CloudVMStateIndex

    /// Future daemon resources are always projected from `document` on read.
    /// Keeping this computed prevents an opaque delta from creating a second,
    /// stale copy of state beside the canonical fragments.
    var otherEntities: [CloudVMEntity] {
        document.opaqueEntities(excluding: Self.modeledSnapshotKeys)
    }

    init(
        machine: SurfaceMachineID,
        cursor: CloudVMCursor?,
        rawSnapshot: Data,
        workspaces: [CloudVMWorkspaceState],
        screens: [CloudVMScreenState],
        panes: [CloudVMPaneState],
        tabs: [CloudVMTabState],
        terminals: [CloudVMTerminalState],
        browsers: [CloudVMBrowserState],
        agents: [CloudVMAgentState],
        lookupIndex: CloudVMStateIndex? = nil,
        document: CloudVMStateDocument? = nil
    ) {
        self.machine = machine
        self.cursor = cursor
        guard let document = document ?? CloudVMStateDocument(data: rawSnapshot) else {
            preconditionFailure("CloudVMState requires a valid canonical snapshot document")
        }
        self.document = document
        self.workspaces = workspaces
        self.screens = screens
        self.panes = panes
        self.tabs = tabs
        self.terminals = terminals
        self.browsers = browsers
        self.agents = agents
        self.lookupIndex = lookupIndex ?? CloudVMStateIndex(
            workspaces: workspaces,
            screens: screens,
            panes: panes,
            tabs: tabs,
            terminals: terminals,
            browsers: browsers,
            agents: agents
        )
    }

    /// Compatibility accessor for callers that need the canonical bytes. This
    /// can be expensive after deltas, so hot paths must use the typed index.
    var rawSnapshot: Data {
        document.data() ?? Data()
    }

    private enum CodingKeys: String, CodingKey {
        case machine, cursor, document, rawSnapshot
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let machine = try container.decode(SurfaceMachineID.self, forKey: .machine)
        let encodedCursor = try container.decodeIfPresent(CloudVMCursor.self, forKey: .cursor)
        let document: CloudVMStateDocument
        if container.contains(.document) {
            document = try container.decode(CloudVMStateDocument.self, forKey: .document)
        } else if let rawSnapshot = try container.decodeIfPresent(Data.self, forKey: .rawSnapshot),
                  let legacyDocument = CloudVMStateDocument(data: rawSnapshot) {
            // Read archives written before the fragment document existed. New
            // archives always write the document key below.
            document = legacyDocument
        } else {
            throw DecodingError.dataCorruptedError(
                forKey: .document,
                in: container,
                debugDescription: "CloudVMState has no valid canonical document"
            )
        }
        guard let object = document.object(),
              let parsed = CmuxTuiSnapshotParser.state(fromSnapshot: object, machine: machine),
              parsed.document == document,
              encodedCursor == nil || encodedCursor == parsed.cursor
        else {
            throw DecodingError.dataCorruptedError(
                forKey: .document,
                in: container,
                debugDescription: "CloudVMState document is invalid or its cursor disagrees with the state"
            )
        }
        self = parsed
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(machine, forKey: .machine)
        try container.encodeIfPresent(cursor, forKey: .cursor)
        try container.encode(document, forKey: .document)
    }

    // New archives contain one canonical document. The decoder keeps a
    // one-way rawSnapshot fallback for archives written before this model.

    static func == (lhs: CloudVMState, rhs: CloudVMState) -> Bool {
        lhs.machine == rhs.machine
            && lhs.cursor == rhs.cursor
            && lhs.document == rhs.document
            && lhs.workspaces == rhs.workspaces
            && lhs.screens == rhs.screens
            && lhs.panes == rhs.panes
            && lhs.tabs == rhs.tabs
            && lhs.terminals == rhs.terminals
            && lhs.browsers == rhs.browsers
            && lhs.agents == rhs.agents
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(machine)
        hasher.combine(cursor)
        hasher.combine(document)
        hasher.combine(workspaces)
        hasher.combine(screens)
        hasher.combine(panes)
        hasher.combine(tabs)
        hasher.combine(terminals)
        hasher.combine(browsers)
        hasher.combine(agents)
    }

    var syncMode: CloudVMStateSyncMode {
        cursor == nil ? .snapshotOnly : .journaled
    }

    var workspaceIDs: Set<String> { Set(workspaces.map(\.id)) }

    func entity(kind: String, id: String) -> CloudVMEntity? {
        let key = Self.snapshotKey(for: kind)
        guard key != "cursor" else { return nil }
        if let entity = document.entity(forCollectionKey: key, id: id) {
            return entity
        }
        // A present fragment with no unique matching identity is deliberately
        // not allowed to fall through to `first`. That would turn duplicate or
        // malformed daemon rows into an unsafe arbitrary selection.
        guard !document.containsFragment(key) else { return nil }
        return otherEntities.first { $0.kind == key && $0.id == id }
    }

    /// Unified read access for agents and future features. Known typed kinds
    /// and opaque kinds use the same plural snapshot-key vocabulary; singular
    /// daemon resource names are accepted as aliases.
    func entities(kind: String) -> [CloudVMEntity] {
        let key = Self.snapshotKey(for: kind)
        guard key != "cursor" else { return [] }
        let objects: [[String: Any]]
        if let collection = document.objects(forCollectionKey: key) {
            objects = collection
        } else if let object = document.value(forKey: key) as? [String: Any] {
            objects = [object]
        } else {
            return otherEntities.filter { $0.kind == key || $0.kind == kind }
        }
        return objects.compactMap { object in
            guard let payload = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
                return nil
            }
            return CloudVMEntity(kind: key, id: object["id"] as? String, payload: payload)
        }
    }

    func snapshotObject() -> [String: Any]? {
        document.object()
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
    /// fields redacted. Synchronization uses the unredacted document; this
    /// boundary only protects the local control socket from leaking pairing or
    /// renderer secrets.
    func agentSnapshotObject() -> [String: Any]? {
        guard let snapshot = snapshotObject() else { return nil }
        return Self.redact(snapshot, context: []) as? [String: Any]
    }

    func agentEntityObject(_ entity: CloudVMEntity) -> Any {
        guard let object = try? JSONSerialization.jsonObject(with: entity.payload, options: [.fragmentsAllowed]) else {
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
    /// Transient local writes whose commit cursor is ahead of the accepted
    /// graph. They are exported so an agent can distinguish a provisional row
    /// from authoritative daemon state. This field is never persisted in the
    /// daemon document and disappears when the receipt is observed.
    var pendingWrites: [CloudVMPendingMutation]? = nil

    static let current = CloudVMStateObservation(freshness: .current, reason: nil, pendingWrites: nil)

    static func stale(reason: String? = nil) -> Self {
        Self(freshness: .stale, reason: reason, pendingWrites: nil)
    }
}

/// Decides whether a complete graph is allowed to cross a pending remote
/// mutation receipt. A receipt carries a daemon generation and revision, so a
/// same-generation graph before the receipt is stale. At the exact receipt
/// cursor, the named value must match. A later cursor is authoritative even
/// when another writer changed the value after our mutation.
enum CloudVMRemoteMutationReceiptDecision: Equatable, Sendable {
    case accept
    case rejectStale
    case rejectConflict

    static func resolve(
        receipt: CloudVMCursor,
        incoming: CloudVMCursor?,
        targetMatches: Bool
    ) -> Self {
        guard let incoming else { return .rejectStale }
        guard incoming.generation == receipt.generation else {
            // Generations are opaque. The caller must separately reject a
            // generation already known to be from an older link; an unseen
            // generation is a new daemon lineage and retires this receipt.
            return .accept
        }
        if incoming.revision < receipt.revision { return .rejectStale }
        if incoming.revision == receipt.revision, !targetMatches {
            return .rejectConflict
        }
        return .accept
    }
}

/// Decides whether a cursor belongs to a generation that this provider may
/// still install. A generation is opaque, so the only safe old-link signal is
/// that the same identifier was already accepted before another generation.
enum CloudVMGenerationAcceptanceDecision: Equatable, Sendable {
    case accept
    case rejectStale

    static func resolve(
        incoming: String,
        current: String?,
        accepted: Set<String>
    ) -> Self {
        accepted.contains(incoming) && current != incoming ? .rejectStale : .accept
    }
}

/// Authority available for a remote rename after one forced refresh. A stale
/// graph is useful for display and export, but it never authorizes a mutation.
/// A pending creation receipt is valid only when that same refresh established
/// the current daemon generation. The tab command carries a revision, not a
/// generation, so an old receipt cannot be used after a failed refresh.
enum CloudVMRemoteMutationAuthority: Equatable, Sendable {
    case currentGraph
    case pendingReceipt
    case snapshotOnly
    case unavailable
    case targetMissing

    static func resolve(
        refreshEstablishedCurrentGraph: Bool,
        hasAcceptedState: Bool,
        targetVisible: Bool,
        hasVersionedCursor: Bool,
        hasPendingReceipt: Bool
    ) -> Self {
        guard refreshEstablishedCurrentGraph, hasAcceptedState else {
            return .unavailable
        }
        guard hasVersionedCursor else {
            return .snapshotOnly
        }
        if targetVisible {
            return .currentGraph
        }
        if hasPendingReceipt {
            return .pendingReceipt
        }
        return .targetMissing
    }
}

/// A local read-your-write receipt. The remote daemon remains authoritative;
/// this value only tells agents why a derived catalog row can temporarily be
/// ahead of the last accepted complete graph.
struct CloudVMPendingMutation: Hashable, Codable, Sendable {
    enum Kind: String, Codable, Sendable {
        case terminalCreate = "terminal_create"
        case workspaceRename = "workspace_rename"
        case tabRename = "tab_rename"
    }

    var kind: Kind
    /// A terminal creation has a resource id. Rename receipts use the stable
    /// daemon id fields below instead, so this is optional by design.
    var resource: SurfaceResourceID?
    var remoteWorkspaceID: String?
    var remoteTabID: String?
    var name: String?
    var receipt: CloudVMCursor?
}

/// A snapshot repairs the document, but it does not by itself repair the live
/// event feed. Keep an existing transport warning until the versioned feed is
/// running again, so an agent never mistakes a point-in-time read for live sync.
enum CloudVMEventFeedRecoveryDecision {
    static func shouldClearWarning(
        snapshotCursor: CloudVMCursor?,
        subscriptionResumed: Bool
    ) -> Bool {
        snapshotCursor != nil && subscriptionResumed
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
        incoming: CloudVMCursor?,
        current: CloudVMCursor?
    ) -> Self {
        // A snapshot without a cursor is a legacy, snapshot-only document. It has
        // no ordering information, so it may initialize an empty slot but must
        // never replace an already journaled graph.
        guard let incoming else {
            return current == nil ? .installSnapshot : .ignoreStale
        }
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
        // The daemon commits exactly one resource revision per session.delta.
        // A larger jump means at least one committed transaction is missing,
        // even when the advertised previous_revision happens to match.
        guard previousRevision < UInt64.max,
              revision == previousRevision + 1 else { return .fetchSnapshot }
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
    /// For browsers and screens: the private URL the projection loads after the
    /// browser Network Extension is ready.
    var url: String?

    var machine: SurfaceMachineID { id.machine }
    var kind: SurfaceResourceKind { id.kind }

    /// How many remote views (daemon tabs) show this resource; 0 when views are not modeled.
    var remoteViewCount: Int { remoteViews?.count ?? 0 }

    /// A live cloud terminal no daemon tab shows: it keeps running on the machine
    /// and is out of every workspace's layout, so it lists only in the machine's
    /// Terminals group, greyed as "detached"; a click re-attaches it in a pane and
    /// only its kill verb ends it. Exited and unavailable records are never marked
    /// detached, even when stale tab ids leave an empty resolved-view list.
    var isDetachedTerminal: Bool {
        guard kind == .terminal, remoteViews?.isEmpty == true else { return false }
        switch lifecycle {
        case .launching, .running:
            return true
        case .exited, .unavailable:
            return false
        }
    }

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
    /// The target exists but holds nothing to open (an empty remote workspace).
    case nothingToOpen(String)
    /// A multi-step remote operation stopped after at least one committed step.
    /// The caller must not hide this behind a generic transport error: the
    /// remote graph may now contain a deliberate partial result.
    case partialOperation(SurfaceResourceID, reason: String)

    var errorDescription: String? {
        switch self {
        case .unknownResource(let id): return "Unknown surface \(id)."
        case .noProvider(let machine): return "No provider for machine \(machine)."
        case .unavailable(let id, let reason): return "\(id) is unavailable: \(reason)"
        case .ambiguousRemotePlacement:
            // Resource and workspace identifiers are internal routing data. Do
            // not expose them in a user-facing error; callers can choose the
            // exact placement with `remote_tab_id`.
            return String(
                localized: "surfaceCatalog.error.ambiguousRemotePlacement",
                defaultValue: "This terminal has more than one remote placement. Specify the remote tab."
            )
        case .destinationNotFound(let what): return "Destination not found: \(what)."
        case .unsupported(let what): return "Unsupported: \(what)."
        case .nothingToOpen(let what): return "Nothing to open: \(what)."
        case .partialOperation(_, let reason): return reason
        }
    }
}
