import Foundation

// Wire types for `list-workspaces` and the tree delta `entity` payloads.
// Shapes follow the serializer (`cmux-tui/crates/cmux-tui-core/src/server.rs`
// workspace_json / screen_json / pane_json), which is richer than the prose
// spec. Every field the GUI can live without decodes leniently so a newer
// daemon never breaks an older app.
//
// Fields gated by `workspace-groups-v1`, `workspace-metadata-v1`,
// `tab-metadata-v1`, `frontend-browser-tabs-v1`, `notification-ack-v1`, and
// `tab-groups-v1` are additive protocol 12 fields (cmux-tui PR 15518,
// cmux-tui/spec/commands.md); older daemons omit them and they decode as
// nil/false/empty.

/// `list-workspaces` result.
public struct DaemonTree: Sendable, Hashable, Decodable {
    public var generation: DaemonGeneration?
    public var registryID: String?
    /// Ordered workspace registry revision. Missing means 0 (old servers).
    public var workspaceRevision: UInt64
    public var paneRevision: UInt64?
    public var terminalRevision: UInt64?
    public var workspaces: [WorkspaceSnapshot]
    /// Ordered sidebar groups (`workspace-groups-v1`).
    public var groups: [WorkspaceGroupSnapshot]
    /// Session-wide saved tab groups (`saved-tab-groups-v1`). Not part of
    /// `list-workspaces`: `DaemonConnection.snapshot()` fills it from
    /// `list-saved-tab-groups`.
    public var savedTabGroups: [SavedTabGroupSnapshot]

    public init(
        generation: DaemonGeneration? = nil,
        registryID: String? = nil,
        workspaceRevision: UInt64 = 0,
        paneRevision: UInt64? = nil,
        terminalRevision: UInt64? = nil,
        workspaces: [WorkspaceSnapshot] = [],
        groups: [WorkspaceGroupSnapshot] = [],
        savedTabGroups: [SavedTabGroupSnapshot] = []
    ) {
        self.generation = generation
        self.registryID = registryID
        self.workspaceRevision = workspaceRevision
        self.paneRevision = paneRevision
        self.terminalRevision = terminalRevision
        self.workspaces = workspaces
        self.groups = groups
        self.savedTabGroups = savedTabGroups
    }

    enum CodingKeys: String, CodingKey {
        case generation
        case registryID = "registry_id"
        case workspaceRevision = "workspace_revision"
        case paneRevision = "pane_revision"
        case terminalRevision = "terminal_revision"
        case workspaces
        case groups
        case savedTabGroups = "saved_tab_groups"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        generation = try c.decodeIfPresent(DaemonGeneration.self, forKey: .generation)
        registryID = try c.decodeIfPresent(String.self, forKey: .registryID)
        workspaceRevision = try c.decodeIfPresent(UInt64.self, forKey: .workspaceRevision) ?? 0
        paneRevision = try c.decodeIfPresent(UInt64.self, forKey: .paneRevision)
        terminalRevision = try c.decodeIfPresent(UInt64.self, forKey: .terminalRevision)
        workspaces = try c.decodeIfPresent([WorkspaceSnapshot].self, forKey: .workspaces) ?? []
        groups = try c.decodeIfPresent([WorkspaceGroupSnapshot].self, forKey: .groups) ?? []
        savedTabGroups = try c.decodeIfPresent([SavedTabGroupSnapshot].self, forKey: .savedTabGroups) ?? []
    }
}

extension DaemonTree {
    /// Sets each saved record's `openGroup` from the live group whose
    /// `savedID` names it.
    public mutating func linkSavedTabGroups() {
        var open: [SavedTabGroupID: TabGroupID] = [:]
        for workspace in workspaces {
            for screen in workspace.screens {
                for pane in screen.panes {
                    for group in pane.tabGroups { if let saved = group.savedID { open[saved] = group.id } }
                }
            }
        }
        for index in savedTabGroups.indices { savedTabGroups[index].openGroup = open[savedTabGroups[index].id] }
    }
}

/// Sidebar section (`workspace-groups-v1`). Groups partition the one
/// workspace order: a section lists its workspaces in `workspaces` order.
public struct WorkspaceGroupSnapshot: Sendable, Hashable, Decodable, Identifiable {
    public var id: WorkspaceGroupID
    public var name: String
    /// Palette token or `#RRGGBB[AA]`.
    public var color: String?
    /// Shared (not per-window) collapsed state.
    public var collapsed: Bool
    public var index: Int

    public init(id: WorkspaceGroupID, name: String, color: String? = nil, collapsed: Bool = false, index: Int = 0) {
        self.id = id
        self.name = name
        self.color = color
        self.collapsed = collapsed
        self.index = index
    }

    enum CodingKeys: String, CodingKey { case id, name, color, collapsed, index }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(WorkspaceGroupID.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        color = try c.decodeIfPresent(String.self, forKey: .color)
        collapsed = try c.decodeIfPresent(Bool.self, forKey: .collapsed) ?? false
        index = try c.decodeIfPresent(Int.self, forKey: .index) ?? 0
    }
}
