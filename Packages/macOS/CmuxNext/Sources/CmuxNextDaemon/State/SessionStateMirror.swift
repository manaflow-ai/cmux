import Foundation

/// The app's copy of the state resources one daemon serves over
/// `session.events` (state-ownership.md 1: a cache rebuilt from the owner's
/// events, never written back). Keyed by public ids, so the store joins it
/// with the raw tree through each model's `resourceID`.
public struct SessionStateMirror: Sendable, Hashable {
    /// Screen pin, color, icon, and group (`ScreenSnapshot.extra`), which the
    /// raw tree does not carry.
    public struct ScreenState: Sendable, Hashable {
        public var pinned = false
        public var color: String?
        public var icon: String?
        public var group: String?

        public init(pinned: Bool = false, color: String? = nil, icon: String? = nil, group: String? = nil) {
            self.pinned = pinned
            self.color = color
            self.icon = icon
            self.group = group
        }
    }

    /// A tab's zoom and browser back/forward list (`TabSnapshot.extra`).
    public struct TabRecord: Sendable, Hashable {
        /// Browser page zoom, or terminal font scale; nil = 1.
        public var zoom: Double?
        public var back: [String] = []
        public var forward: [String] = []

        public init(zoom: Double? = nil, back: [String] = [], forward: [String] = []) {
            self.zoom = zoom
            self.back = back
            self.forward = forward
        }

        var isEmpty: Bool { zoom == nil && back.isEmpty && forward.isEmpty }
    }

    /// Newest first, at most `closedLimit`.
    public var closed: [ClosedItem] = []
    public var workspaceStatus: [ResourceID: WorkspaceStatus] = [:]
    public var ephemeralWorkspaces: Set<ResourceID> = []
    /// Each workspace's agent folder (`extra.agent_folder`), where its new agent chats start.
    public var agentFolders: [ResourceID: String] = [:]
    public var screens: [ResourceID: ScreenState] = [:]
    public var screenGroups: [String: StateScreenGroup] = [:]
    public var tabs: [ResourceID: TabRecord] = [:]
    public var terminalProgress: [ResourceID: TerminalProgressReport] = [:]
    /// OSC 7501 records per terminal; a terminal without records is absent.
    public var terminalProgramStatus: [ResourceID: [ProgramStatusRecord]] = [:]

    /// The daemon keeps the newest 50 closed items.
    public static let closedLimit = 50

    public init() {}

    /// Applies one ordered batch of changes.
    public mutating func apply(_ changes: [SessionStateChange]) {
        for change in changes { apply(change) }
    }

    public mutating func apply(_ change: SessionStateChange) {
        switch change {
        case .workspace(let id, let ephemeral, let agentFolder):
            if ephemeral { ephemeralWorkspaces.insert(id) } else { ephemeralWorkspaces.remove(id) }
            agentFolders[id] = agentFolder
        case .workspaceRemoved(let id):
            ephemeralWorkspaces.remove(id)
            agentFolders[id] = nil
            workspaceStatus[id] = nil
        case .screen(let id, let state):
            screens[id] = state
        case .tab(let id, let record):
            tabs[id] = record.flatMap { $0.isEmpty ? nil : $0 }
        case .terminal(let id, let progress, let programStatus):
            terminalProgress[id] = progress
            terminalProgramStatus[id] = programStatus.isEmpty ? nil : programStatus
        case .closed(let item):
            closed.removeAll { $0.id == item.id }
            let index = closed.firstIndex { $0.closedAtMs < item.closedAtMs } ?? closed.endIndex
            closed.insert(item, at: index)
            if closed.count > Self.closedLimit { closed.removeLast(closed.count - Self.closedLimit) }
        case .closedRemoved(let id):
            closed.removeAll { $0.id == id }
        case .status(let status):
            workspaceStatus[status.workspaceID] = status
        case .statusRemoved(let workspace):
            workspaceStatus[workspace] = nil
        case .screenGroup(let group):
            screenGroups[group.id] = group
        case .screenGroupRemoved(let id):
            screenGroups[id] = nil
        }
    }

    /// The screen groups of `workspace`, ordered by their first member's
    /// position in `screenOrder` (the workspace's screen ids in order).
    public func screenGroups(of workspace: ResourceID, screenOrder: [ResourceID]) -> [StateScreenGroup] {
        let position = Dictionary(screenOrder.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        return screenGroups.values.filter { $0.workspaceID == workspace }.sorted { lhs, rhs in
            let l = lhs.screenIDs.compactMap { position[$0] }.min() ?? Int.max
            let r = rhs.screenIDs.compactMap { position[$0] }.min() ?? Int.max
            return l != r ? l < r : lhs.id < rhs.id
        }
    }
}

/// A screen group (`ScreenGroupSnapshot` in the v2 catalog): named, colored,
/// collapsible, members contiguous in screen order.
public struct StateScreenGroup: Sendable, Hashable, Decodable {
    /// `sgrp_…` state id.
    public var id: String
    public var workspaceID: ResourceID
    public var name: String
    public var color: String?
    public var collapsed: Bool
    public var screenIDs: [ResourceID]
    /// The saved screen group this live group is linked to.
    public var savedID: String?

    enum CodingKeys: String, CodingKey {
        case id, name, color, collapsed
        case workspaceID = "workspace_id"
        case screenIDs = "screen_ids"
        case savedID = "saved_id"
    }

    public init(id: String, workspaceID: ResourceID, name: String = "", color: String? = nil, collapsed: Bool = false,
                screenIDs: [ResourceID] = [], savedID: String? = nil) {
        self.id = id
        self.workspaceID = workspaceID
        self.name = name
        self.color = color
        self.collapsed = collapsed
        self.screenIDs = screenIDs
        self.savedID = savedID
    }
}

/// Decimal-string integers of the v2 protocol (`"1790000000000"`); also
/// accepts a JSON number.
enum StateDecimal {
    static func decode<K: CodingKey>(_ container: KeyedDecodingContainer<K>, _ key: K) throws -> UInt64? {
        if let text = try? container.decodeIfPresent(String.self, forKey: key) { return UInt64(text) }
        return try container.decodeIfPresent(UInt64.self, forKey: key)
    }
}
