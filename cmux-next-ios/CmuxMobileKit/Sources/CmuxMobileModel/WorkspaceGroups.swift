import Foundation

/// One of the Mac's workspace groups: a personal sidebar group of the person
/// (`list-personal.groups`, cmux-next `WorkspaceGroupSnapshot`).
public struct MacWorkspaceGroup: Identifiable, Hashable, Sendable, Codable {
    public var id: String
    public var name: String
    /// A palette name (`WorkspaceColor`) or `#RRGGBB`; nil for none.
    public var color: String?
    public var isCollapsed: Bool
    /// The group's place among the groups.
    public var index: Int
    /// The personal row the group shows right before (`top_index`); nil after every loose workspace.
    public var topIndex: Int?
    /// The room the group belongs to (`profile`).
    public var room: String?

    public init(id: String, name: String, color: String? = nil, isCollapsed: Bool = false, index: Int = 0,
                topIndex: Int? = nil, room: String? = nil) {
        self.id = id
        self.name = name
        self.color = color
        self.isCollapsed = isCollapsed
        self.index = index
        self.topIndex = topIndex
        self.room = room
    }

    /// The name, else "Unnamed Group" (the Mac's `unnamedGroup`).
    public var displayName: String {
        name.trimmingCharacters(in: .whitespaces).isEmpty ? "Unnamed Group" : name
    }

    /// The Mac's name for a group made without one (`SidebarGroup.named`).
    public static let newGroupName = "New Group"

    /// The Mac's next group color (`GroupColor.automatic`): the first of its
    /// automatic order no group uses, never blue or grey; grey when all are used.
    public static func nextColor(used: Set<String>) -> WorkspaceColor {
        let order: [WorkspaceColor] = [.red, .green, .yellow, .purple, .cyan, .orange, .pink]
        return order.first { !used.contains($0.rawValue) } ?? .grey
    }
}

extension SidebarArrangement {
    /// A room (`list-personal.profiles[]`): its order and the sessions it follows.
    public struct Room: Equatable, Sendable {
        public var id: String
        public var index: Int
        public var follows: [String]

        public init(id: String, index: Int, follows: [String] = []) {
            self.id = id
            self.index = index
            self.follows = follows
        }
    }

    /// A workspace pinned to one room (`list-personal.pins[]`).
    public struct RoomPin: Equatable, Sendable {
        public var session: String
        public var key: String
        public var room: String

        public init(session: String, key: String, room: String) {
            self.session = session
            self.key = key
            self.room = room
        }
    }

    /// The room every Mac has (`DEFAULT_PROFILE_ID`).
    public static let defaultRoom = "default"

    private static func personalData(_ reply: [String: Any]) -> [String: Any] {
        reply["data"] as? [String: Any] ?? reply
    }

    /// Parses `list-personal.groups`.
    public static func groups(personal reply: [String: Any]) -> [MacWorkspaceGroup] {
        (personalData(reply)["groups"] as? [[String: Any]] ?? []).compactMap { group in
            guard let id = group["id"] as? String else { return nil }
            return MacWorkspaceGroup(id: id, name: group["name"] as? String ?? "", color: group["color"] as? String,
                                     isCollapsed: group["collapsed"] as? Bool ?? false, index: group["index"] as? Int ?? 0,
                                     topIndex: group["top_index"] as? Int, room: group["profile"] as? String)
        }
    }

    /// Parses `list-personal.profiles`.
    public static func rooms(personal reply: [String: Any]) -> [Room] {
        (personalData(reply)["profiles"] as? [[String: Any]] ?? []).compactMap { room in
            guard let id = room["id"] as? String else { return nil }
            return Room(id: id, index: room["index"] as? Int ?? 0, follows: room["follows"] as? [String] ?? [])
        }
    }

    /// Parses `list-personal.pins`.
    public static func roomPins(personal reply: [String: Any]) -> [RoomPin] {
        (personalData(reply)["pins"] as? [[String: Any]] ?? []).compactMap { pin in
            guard let session = pin["session_id"] as? String, let key = pin["workspace_key"] as? String,
                  let room = pin["profile"] as? String else { return nil }
            return RoomPin(session: session, key: key, room: room)
        }
    }

    /// The groups whose workspaces are all of session `registryID` (or that are
    /// empty), in the Mac's group order: the groups a phone may change and move
    /// this Mac's workspaces into (a Mac group holds one machine's workspaces).
    public func ownGroups(registryID: String) -> [MacWorkspaceGroup] {
        let others = Set((rows ?? []).filter { $0.session != registryID }.compactMap(\.group))
        return groups.filter { !others.contains($0.id) }.sorted { $0.index < $1.index }
    }

    /// The room a new group for workspace `key` goes to, as the Mac's window
    /// that shows it: the room it is pinned to, else the first room (in room
    /// order) that follows this session, else the default room.
    public func room(forWorkspace key: String, registryID: String) -> String {
        if let pin = roomPins.first(where: { $0.session == registryID && $0.key == key }) { return pin.room }
        return rooms.sorted { $0.index < $1.index }.first { $0.follows.contains(registryID) }?.id ?? Self.defaultRoom
    }

    /// The Mac's mixed sidebar order with groups (cmux-next
    /// `PersonalSidebar.mixedSections`): walk every personal row by place;
    /// before row i come the groups whose `top_index` is i (members in personal
    /// order), then row i when it is loose. Workspaces without a row follow,
    /// then the groups placed after every row. Each workspace gets its place
    /// in that order and its group.
    func applyGroups(to workspaces: inout [Workspace], registryID: String) {
        let ordered = (rows ?? []).sorted { $0.index < $1.index }
        let byID = Dictionary(groups.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let mine = ordered.filter { $0.session == registryID }
        let groupOf: [String: String] = Dictionary(
            mine.compactMap { row in row.group.flatMap { byID[$0] != nil ? (row.key, $0) : nil } }, uniquingKeysWith: { first, _ in first })
        let sortedGroups = groups.sorted { $0.index < $1.index }
        var sequence: [String] = []
        func emit(_ group: MacWorkspaceGroup) {
            sequence += mine.filter { groupOf[$0.key] == group.id }.map(\.key)
        }
        for (index, row) in ordered.enumerated() {
            for group in sortedGroups where group.topIndex == index { emit(group) }
            if row.session == registryID, groupOf[row.key] == nil { sequence.append(row.key) }
        }
        let rowed = Set(mine.map(\.key))
        sequence += workspaces.map(\.id).filter { !rowed.contains($0) }
        for group in sortedGroups where group.topIndex.map({ $0 >= ordered.count }) ?? true { emit(group) }
        let position = Dictionary(sequence.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        for i in workspaces.indices {
            let id = workspaces[i].id
            workspaces[i].sidebarIndex = position[id] ?? sequence.count + i
            workspaces[i].group = groupOf[id].flatMap { byID[$0] }
        }
    }
}

/// The Mac's workspace group actions, for a backend that can send them
/// (cmux-next-ios/SECURITY.md "Workspace groups").
@MainActor
public protocol WorkspaceGroupBackend: AnyObject {
    /// The Mac's groups this phone may use there (all of that Mac's workspaces, or empty), in its order.
    func groups(on macID: String) -> [MacWorkspaceGroup]
    /// Move Workspace to Group… (a group) / Remove Workspace from Group (nil).
    func place(_ workspace: Workspace, in group: MacWorkspaceGroup?) async throws
    /// Move Workspace to New Group: a new group with `name` and `color`, holding the workspace.
    func moveToNewGroup(_ workspace: Workspace, name: String, color: WorkspaceColor) async throws
    /// Rename Group…, the group's color, Collapse / Expand Workspace Group.
    func updateGroup(_ group: MacWorkspaceGroup, on macID: String, name: String?, color: WorkspaceColor?, collapsed: Bool?) async throws
    /// Ungroup Workspaces / Delete Group: the group goes, its workspaces stay.
    func deleteGroup(_ group: MacWorkspaceGroup, on macID: String) async throws
}

extension WorkspaceCreator {
    private var grouper: (any WorkspaceGroupBackend)? { backend as? any WorkspaceGroupBackend }

    /// The Mac's groups the workspace can move into (not its own group).
    public func groupChoices(for workspace: Workspace) -> [MacWorkspaceGroup] {
        guard canArrange(workspace), let grouper else { return [] }
        return grouper.groups(on: workspace.macID).filter { $0.id != workspace.group?.id }
    }

    /// Whether the workspace's group can change from here now.
    public func canGroup(_ workspace: Workspace) -> Bool {
        canArrange(workspace) && grouper != nil
    }

    /// Move Workspace to Group… / Remove Workspace from Group (nil): at once,
    /// undone if the Mac refuses.
    public func place(_ workspace: Workspace, in group: MacWorkspaceGroup?) {
        guard canGroup(workspace), workspace.group?.id != group?.id, let grouper else { return }
        let old = store.updateWorkspace(workspace.id) { $0.group = group }
        let failure = group == nil ? "Couldn't remove \(workspace.title) from its group" : "Couldn't move \(workspace.title) to \(group?.displayName ?? "")"
        regroup([old].compactMap { $0 }, workspace: workspace, failure: failure) {
            try await grouper.place(workspace, in: group)
        }
    }

    /// Move Workspace to New Group: a new group (the Mac's next color; "New
    /// Group" when no name is given) shows at once with the workspace in it.
    public func moveToNewGroup(_ workspace: Workspace, name: String) {
        guard canGroup(workspace), let grouper else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmed.isEmpty ? MacWorkspaceGroup.newGroupName : trimmed
        let used = Set(grouper.groups(on: workspace.macID).compactMap(\.color))
        let color = MacWorkspaceGroup.nextColor(used: used)
        let pending = MacWorkspaceGroup(id: "pending-\(UUID().uuidString)", name: name, color: color.rawValue)
        let old = store.updateWorkspace(workspace.id) { $0.group = pending }
        regroup([old].compactMap { $0 }, workspace: workspace, failure: "Couldn't make a group for \(workspace.title)") {
            try await grouper.moveToNewGroup(workspace, name: name, color: color)
        }
    }

    /// Rename Group…: every member shows the new name at once.
    public func renameGroup(_ group: MacWorkspaceGroup, on macID: String, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != group.name else { return }
        updateGroup(group, on: macID, failure: "Couldn't rename \(group.displayName)", { $0.name = name }) { grouper in
            try await grouper.updateGroup(group, on: macID, name: name, color: nil, collapsed: nil)
        }
    }

    /// The group's color (one of the Mac's nine).
    public func setGroupColor(_ group: MacWorkspaceGroup, on macID: String, _ color: WorkspaceColor) {
        guard group.color != color.rawValue else { return }
        updateGroup(group, on: macID, failure: "Couldn't change the color of \(group.displayName)", { $0.color = color.rawValue }) { grouper in
            try await grouper.updateGroup(group, on: macID, name: nil, color: color, collapsed: nil)
        }
    }

    /// Collapse Workspace Group / Expand Workspace Group (the Mac's sidebar folds too).
    public func setGroupCollapsed(_ group: MacWorkspaceGroup, on macID: String, _ collapsed: Bool) {
        guard group.isCollapsed != collapsed else { return }
        let failure = collapsed ? "Couldn't collapse \(group.displayName)" : "Couldn't expand \(group.displayName)"
        updateGroup(group, on: macID, failure: failure, { $0.isCollapsed = collapsed }) { grouper in
            try await grouper.updateGroup(group, on: macID, name: nil, color: nil, collapsed: collapsed)
        }
    }

    /// Ungroup Workspaces / Delete Group: the members leave the group at once
    /// and stay open; they come back into it if the Mac refuses.
    public func deleteGroup(_ group: MacWorkspaceGroup, on macID: String) {
        updateGroup(group, on: macID, failure: "Couldn't delete \(group.displayName)", { _ in }, removes: true) { grouper in
            try await grouper.deleteGroup(group, on: macID)
        }
    }

    private func updateGroup(_ group: MacWorkspaceGroup, on macID: String, failure: String, _ change: (inout MacWorkspaceGroup) -> Void,
                             removes: Bool = false, _ work: @escaping @MainActor (any WorkspaceGroupBackend) async throws -> Void) {
        // The phone shows a group by its members: one of them names the change.
        let members = store.workspaces.filter { $0.macID == macID && $0.group?.id == group.id }
        guard let grouper, let first = members.first, canArrange(first) else { return }
        var changed = group
        change(&changed)
        let old = members.compactMap { ws in store.updateWorkspace(ws.id) { $0.group = removes ? nil : changed } }
        regroup(old, workspace: first, failure: failure) { try await work(grouper) }
    }

    private func regroup(_ old: [Workspace], workspace: Workspace, failure: String, _ work: @escaping @MainActor () async throws -> Void) {
        track(workspace.id) { [weak self] in
            do {
                try await work()
            } catch {
                for ws in old { self?.store.updateWorkspace(ws.id) { $0.group = ws.group } }
                self?.onManageFailure?(workspace, failure, Self.message(error))
            }
        }
    }
}

#if DEBUG
/// Mock mode: every group change is accepted after the mock latency; no groups to list.
extension MockWorkspaceCreationBackend: WorkspaceGroupBackend {
    public func groups(on macID: String) -> [MacWorkspaceGroup] { [] }
    public func place(_ workspace: Workspace, in group: MacWorkspaceGroup?) async throws { try await rename(workspace, to: workspace.title) }
    public func moveToNewGroup(_ workspace: Workspace, name: String, color: WorkspaceColor) async throws { try await rename(workspace, to: workspace.title) }
    public func updateGroup(_ group: MacWorkspaceGroup, on macID: String, name: String?, color: WorkspaceColor?, collapsed: Bool?) async throws {}
    public func deleteGroup(_ group: MacWorkspaceGroup, on macID: String) async throws {}
}
#endif
