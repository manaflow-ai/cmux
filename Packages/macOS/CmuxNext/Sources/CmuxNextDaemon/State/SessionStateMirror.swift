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
        /// The user's icon for the tab (the shared icon wire string, `IconValue`), or nil.
        public var icon: String?
        /// A browser tab's device emulation as the daemon resolved it
        /// (`extra.emulation`, browser-devices-v1), or nil.
        public var emulation: JSONValue?
        /// Marked unread by hand (Mark Tab Unread, `extra.marked_unread`, tab-mark-unread-v1),
        /// apart from notification markers.
        public var markedUnread: Bool
        /// An agent needs the person to act in this tab (`extra.attention`, tab-attention-v1), or nil.
        public var attention: TabAttention?

        public init(zoom: Double? = nil, back: [String] = [], forward: [String] = [], icon: String? = nil,
                    emulation: JSONValue? = nil, markedUnread: Bool = false, attention: TabAttention? = nil) {
            self.zoom = zoom
            self.back = back
            self.forward = forward
            self.icon = icon
            self.emulation = emulation
            self.markedUnread = markedUnread
            self.attention = attention
        }

        var isEmpty: Bool {
            zoom == nil && back.isEmpty && forward.isEmpty && icon == nil && emulation == nil && !markedUnread && attention == nil
        }
    }

    /// Newest first, at most `closedLimit`.
    public var closed: [ClosedItem] = []
    public var workspaceStatus: [ResourceID: WorkspaceStatus] = [:]
    /// Each workspace's checklist (`workspace-checklist-v1`); a workspace without items is absent.
    public var workspaceChecklists: [ResourceID: WorkspaceChecklist] = [:]
    public var ephemeralWorkspaces: Set<ResourceID> = []
    /// Each workspace's agent folder (`extra.agent_folder`), where its new agent chats start.
    public var agentFolders: [ResourceID: String] = [:]
    /// Each workspace's description and manual task status; absent while neither is set.
    public var workspaceNotes: [ResourceID: WorkspaceNotes] = [:]
    public var screens: [ResourceID: ScreenState] = [:]
    public var screenGroups: [String: StateScreenGroup] = [:]
    public var tabs: [ResourceID: TabRecord] = [:]
    public var terminalProgress: [ResourceID: TerminalProgressReport] = [:]
    /// OSC 7501 records per terminal; a terminal without records is absent.
    public var terminalProgramStatus: [ResourceID: [ProgramStatusRecord]] = [:]
    /// When each terminal's running shell command started; a terminal at a prompt is absent.
    public var terminalBusySinceMs: [ResourceID: UInt64] = [:]
    /// Since when each terminal's shell sits at its prompt; absent while a command runs and without
    /// shell integration.
    public var terminalPromptSinceMs: [ResourceID: UInt64] = [:]
    /// When each terminal last printed.
    public var terminalLastOutputMs: [ResourceID: UInt64] = [:]

    /// The daemon keeps the newest 50 closed items.
    public static let closedLimit = 50

    public init() {}

    /// A record a change touched: what `SessionStateStore` lays over the
    /// tree's records again (only those, never the whole tree).
    public enum Touched: Hashable, Sendable {
        /// The workspace's own state: ephemeral, agent folder, status, screen groups.
        case workspace(ResourceID)
        case screen(ResourceID)
        case tab(ResourceID)
        case terminal(ResourceID)
        case closed
        /// A stash (`stash-v1`): the mirror keeps none, so readers list the stashes again.
        case stash
    }

    /// Applies one ordered batch of changes in place.
    public mutating func apply(_ changes: [SessionStateChange]) {
        var touched: Set<Touched> = []
        for change in changes { apply(change, touched: &touched) }
    }

    /// Applies one change in place.
    public mutating func apply(_ change: SessionStateChange) {
        var touched: Set<Touched> = []
        apply(change, touched: &touched)
    }

    /// Applies one change in place and adds the record it changed to
    /// `touched`; a change that leaves the value as it was adds nothing.
    /// O(1) per change (the closed list is bounded by `closedLimit`).
    public mutating func apply(_ change: SessionStateChange, touched: inout Set<Touched>) {
        switch change {
        case .workspace(let id, let ephemeral, let agentFolder, let notes):
            let changed = ephemeral ? ephemeralWorkspaces.insert(id).inserted : ephemeralWorkspaces.remove(id) != nil
            let notes = notes.isEmpty ? nil : notes
            if changed || agentFolders[id] != agentFolder || workspaceNotes[id] != notes {
                agentFolders[id] = agentFolder
                workspaceNotes[id] = notes
                touched.insert(.workspace(id))
            }
        case .workspaceRemoved(let id):
            let removed = [ephemeralWorkspaces.remove(id) != nil, agentFolders.removeValue(forKey: id) != nil,
                           workspaceStatus.removeValue(forKey: id) != nil, workspaceNotes.removeValue(forKey: id) != nil,
                           workspaceChecklists.removeValue(forKey: id) != nil]
            if removed.contains(true) { touched.insert(.workspace(id)) }
        case .screen(let id, let state):
            guard screens[id] != state else { return }
            screens[id] = state
            touched.insert(.screen(id))
        case .tab(let id, let record):
            let record = record.flatMap { $0.isEmpty ? nil : $0 }
            guard tabs[id] != record else { return }
            tabs[id] = record
            touched.insert(.tab(id))
        case .terminal(let id, let progress, let programStatus, let busySinceMs, let promptSinceMs, let lastOutputMs):
            let status = programStatus.isEmpty ? nil : programStatus
            guard terminalProgress[id] != progress || terminalProgramStatus[id] != status || terminalBusySinceMs[id] != busySinceMs
                || terminalPromptSinceMs[id] != promptSinceMs || terminalLastOutputMs[id] != lastOutputMs else {
                return
            }
            terminalProgress[id] = progress
            terminalProgramStatus[id] = status
            terminalBusySinceMs[id] = busySinceMs
            terminalPromptSinceMs[id] = promptSinceMs
            terminalLastOutputMs[id] = lastOutputMs
            touched.insert(.terminal(id))
        case .closed(let item):
            let before = closed
            closed.removeAll { $0.id == item.id }
            let index = closed.firstIndex { $0.closedAtMs < item.closedAtMs } ?? closed.endIndex
            closed.insert(item, at: index)
            if closed.count > Self.closedLimit { closed.removeLast(closed.count - Self.closedLimit) }
            if closed != before { touched.insert(.closed) }
        case .closedRemoved(let id):
            guard closed.contains(where: { $0.id == id }) else { return }
            closed.removeAll { $0.id == id }
            touched.insert(.closed)
        case .status(let status):
            guard workspaceStatus[status.workspaceID] != status else { return }
            workspaceStatus[status.workspaceID] = status
            touched.insert(.workspace(status.workspaceID))
        case .statusRemoved(let workspace):
            guard workspaceStatus.removeValue(forKey: workspace) != nil else { return }
            touched.insert(.workspace(workspace))
        case .checklist(let checklist):
            let value = checklist.items.isEmpty ? nil : checklist
            guard workspaceChecklists[checklist.workspaceID] != value else { return }
            workspaceChecklists[checklist.workspaceID] = value
            touched.insert(.workspace(checklist.workspaceID))
        case .checklistRemoved(let workspace):
            guard workspaceChecklists.removeValue(forKey: workspace) != nil else { return }
            touched.insert(.workspace(workspace))
        case .screenGroup(let group):
            let old = screenGroups[group.id]
            guard old != group else { return }
            screenGroups[group.id] = group
            touched.insert(.workspace(group.workspaceID))
            if let old, old.workspaceID != group.workspaceID { touched.insert(.workspace(old.workspaceID)) }
        case .screenGroupRemoved(let id):
            guard let old = screenGroups.removeValue(forKey: id) else { return }
            touched.insert(.workspace(old.workspaceID))
        case .stash:
            touched.insert(.stash)
        case .sidebarBatch:
            // The sidebar document has its own mirror (SessionStateStore.onSidebarBatch).
            break
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
    /// The shared icon string (`screen-group-icon-v1`); nil is none.
    public var icon: String?

    enum CodingKeys: String, CodingKey {
        case id, name, color, collapsed, icon
        case workspaceID = "workspace_id"
        case screenIDs = "screen_ids"
        case savedID = "saved_id"
    }

    public init(id: String, workspaceID: ResourceID, name: String = "", color: String? = nil, collapsed: Bool = false,
                screenIDs: [ResourceID] = [], savedID: String? = nil, icon: String? = nil) {
        self.id = id
        self.workspaceID = workspaceID
        self.name = name
        self.color = color
        self.collapsed = collapsed
        self.screenIDs = screenIDs
        self.savedID = savedID
        self.icon = icon
    }
}

/// Decimal-string integers of the v2 protocol (`"1790000000000"`); also
/// accepts a JSON number.
enum StateDecimal {
    static func decode<K: CodingKey>(_ container: KeyedDecodingContainer<K>, _ key: K) throws -> UInt64? {
        if let text = try? container.decodeIfPresent(String.self, forKey: key) { return UInt64(text, radix: 10) }
        return try container.decodeIfPresent(UInt64.self, forKey: key)
    }
}
