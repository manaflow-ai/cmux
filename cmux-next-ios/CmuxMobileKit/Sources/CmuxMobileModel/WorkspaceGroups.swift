import Foundation
#if os(iOS)
import CmuxMobileLinkFFI
#endif

// The group rules (mixed sidebar order, own groups, a new group's room, color
// and name, shown groups, folds, edits held over refreshes) are Rust's
// (cmux-mobile-link-ffi `workspace_groups`, Leo 2026-11-25: "i was wondering
// why we even have swift at all"). This file hands it the state and applies
// the answer; only the iOS build links Rust, so elsewhere (the Linux and macOS
// package tests) the answers are the no-groups ones.

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
    /// A pinned (saved) group stays, folded, when its workspaces close (`pinned`); nil from an
    /// older Mac or an older cache.
    public var isPinned: Bool?

    public init(id: String, name: String, color: String? = nil, isCollapsed: Bool = false, index: Int = 0,
                topIndex: Int? = nil, room: String? = nil, isPinned: Bool? = nil) {
        self.id = id
        self.name = name
        self.color = color
        self.isCollapsed = isCollapsed
        self.index = index
        self.topIndex = topIndex
        self.room = room
        self.isPinned = isPinned
    }

    /// The name, else "Unnamed Group" (the Mac's `unnamedGroup`).
    public var displayName: String {
        #if os(iOS)
        workspaceGroupDisplayName(name: name)
        #else
        name
        #endif
    }

    /// The Mac's name for a group made without one (`SidebarGroup.named`).
    public static let newGroupName = "New Group"

    /// The Mac's next group color (`GroupColor.automatic`): the first of its
    /// automatic order no group uses, never blue or grey; grey when all are used.
    public static func nextColor(used: Set<String>) -> WorkspaceColor {
        #if os(iOS)
        WorkspaceColor(rawValue: workspaceGroupNextColor(used: used.sorted())) ?? .grey
        #else
        .grey
        #endif
    }

    /// Move Workspace to New Group's name: what was typed, trimmed; "New Group" when blank.
    public static func chosenName(typed: String) -> String {
        #if os(iOS)
        workspaceGroupNewName(typed: typed)
        #else
        newGroupName
        #endif
    }

    /// Rename Group…'s new name: what was typed, trimmed; nil when blank or unchanged.
    func renamed(to typed: String) -> String? {
        #if os(iOS)
        workspaceGroupRename(current: name, typed: typed)
        #else
        nil
        #endif
    }
}

#if os(iOS)
extension MacWorkspaceGroup {
    init(_ info: WorkspaceGroupInfo) {
        self.init(id: info.id, name: info.name, color: info.color, isCollapsed: info.collapsed, index: Int(info.index),
                  topIndex: info.topIndex.map(Int.init), room: info.room, isPinned: info.pinned)
    }

    var info: WorkspaceGroupInfo {
        WorkspaceGroupInfo(id: id, name: name, color: color, collapsed: isCollapsed, index: Int64(index),
                           topIndex: topIndex.map(Int64.init), room: room, pinned: isPinned)
    }
}

extension SidebarArrangement {
    var groupRows: [WorkspaceGroupRow] {
        (rows ?? []).map { WorkspaceGroupRow(session: $0.session, key: $0.key, index: Int64($0.index), group: $0.group) }
    }
}
#endif

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
                                     topIndex: group["top_index"] as? Int, room: group["profile"] as? String,
                                     isPinned: group["pinned"] as? Bool)
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
        #if os(iOS)
        workspaceGroupOwn(rows: groupRows, groups: groups.map(\.info), registryId: registryID).map { groups[Int($0)] }
        #else
        []
        #endif
    }

    /// The room a new group for workspace `key` goes to, as the Mac's window
    /// that shows it: the room it is pinned to, else the first room (in room
    /// order) that follows this session, else the default room.
    public func room(forWorkspace key: String, registryID: String) -> String {
        #if os(iOS)
        workspaceGroupRoom(rooms: rooms.map { WorkspaceGroupRoom(id: $0.id, index: Int64($0.index), follows: $0.follows) },
                           pins: roomPins.map { WorkspaceGroupRoomPin(session: $0.session, key: $0.key, room: $0.room) },
                           key: key, registryId: registryID)
        #else
        Self.defaultRoom
        #endif
    }

    /// The Mac's mixed sidebar order with groups (cmux-next
    /// `PersonalSidebar.mixedSections`): walk every personal row by place;
    /// before row i come the groups whose `top_index` is i (members in personal
    /// order), then row i when it is loose. Workspaces without a row follow,
    /// then the groups placed after every row. Each workspace gets its place
    /// in that order and its group.
    func applyGroups(to workspaces: inout [Workspace], registryID: String) {
        #if os(iOS)
        let placements = workspaceGroupPlacements(rows: groupRows, groups: groups.map(\.info),
                                                  workspaceIds: workspaces.map(\.id), registryId: registryID)
        for (i, placement) in zip(workspaces.indices, placements) {
            workspaces[i].sidebarIndex = Int(placement.sidebarIndex)
            workspaces[i].group = placement.group.map { groups[Int($0)] }
        }
        #endif
    }
}

/// Group edits this phone made that the Mac's list has not shown back yet.
///
/// The phone shows a group change at once and sends it to the Mac. Until the
/// Mac's list carries it, a tree refresh (a terminal title, an agent event, a
/// notification) can publish the group as it was: the list's arrangement is
/// cached and only re-read after the Mac answers. Without this a collapsed
/// group opened again by itself, and a second tap seemed to be needed
/// ("disclosure groups not being properly closable"). An edit holds its
/// members' group over refreshes while it is in flight, and after the Mac's
/// yes until a refresh shows it or `confirmWindow` passes; then the Mac's
/// state wins again (another device may change it). Only the latest edit of
/// a workspace counts: a refused earlier tap does not undo a later one.
struct PendingGroupEdits: Sendable {
    #if os(iOS)
    private let ledger = GroupEditLedger()

    var isEmpty: Bool { ledger.isEmpty() }

    /// The workspaces now show `group` (nil: no group); returns the edit's
    /// generation. It replaces any earlier edit of those workspaces.
    mutating func begin(_ workspaceIDs: [String], group: MacWorkspaceGroup?, holds: Bool = true) -> Int {
        Int(ledger.begin(workspaceIds: workspaceIDs, group: group?.info, holds: holds))
    }

    /// The edit's request left for the Mac (after the Mac's earlier group
    /// requests): the unanswered window counts from here.
    mutating func sent(_ workspaceIDs: [String], generation: Int, at date: Date) {
        ledger.sent(workspaceIds: workspaceIDs, generation: UInt64(generation), atMs: Self.ms(date))
    }

    /// The Mac accepted the edit: refreshes keep it until one shows it (a
    /// non-holding edit is done).
    mutating func answered(_ workspaceIDs: [String], generation: Int, at date: Date) {
        ledger.answered(workspaceIds: workspaceIDs, generation: UInt64(generation), atMs: Self.ms(date))
    }

    /// Forgets every edit (sign-in); generations keep counting.
    mutating func removeAll() {
        ledger.removeAll()
    }

    /// The Mac refused the edit: the workspaces it was still the latest edit
    /// of (those to roll back).
    mutating func refused(_ workspaceIDs: [String], generation: Int) -> Set<String> {
        Set(ledger.refused(workspaceIds: workspaceIDs, generation: UInt64(generation)))
    }

    /// One Mac's refreshed rows, with the edits they do not show yet.
    mutating func apply(to rows: inout [Workspace], now: Date) {
        guard !ledger.isEmpty() else { return }
        let held = ledger.apply(rows: rows.map { GroupEditRow(id: $0.id, group: $0.group?.info) }, nowMs: Self.ms(now))
        for edit in held { rows[Int(edit.index)].group = edit.group.map(MacWorkspaceGroup.init) }
    }

    private static func ms(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1000).rounded()) }
    #else
    var isEmpty: Bool { true }
    mutating func begin(_ workspaceIDs: [String], group: MacWorkspaceGroup?, holds: Bool = true) -> Int { 0 }
    mutating func sent(_ workspaceIDs: [String], generation: Int, at date: Date) {}
    mutating func answered(_ workspaceIDs: [String], generation: Int, at date: Date) {}
    mutating func removeAll() {}
    mutating func refused(_ workspaceIDs: [String], generation: Int) -> Set<String> { Set(workspaceIDs) }
    mutating func apply(to rows: inout [Workspace], now: Date) {}
    #endif
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
    /// New Workspace Group: an empty group with `name` and `color` on `macID`, returned once the
    /// Mac made it (Duplicate Workspace Group then places each copy in it).
    func createGroup(named name: String, color: WorkspaceColor, on macID: String) async throws -> MacWorkspaceGroup
    /// Rename Group…, the group's color, Collapse / Expand Workspace Group.
    func updateGroup(_ group: MacWorkspaceGroup, on macID: String, name: String?, color: WorkspaceColor?, collapsed: Bool?) async throws
    /// Ungroup Workspaces / Delete Group: the group goes, its workspaces stay.
    func deleteGroup(_ group: MacWorkspaceGroup, on macID: String) async throws
}

extension WorkspaceCreator {
    var grouper: (any WorkspaceGroupBackend)? { backend as? any WorkspaceGroupBackend }

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
        let generation = store.groupEdits.begin([workspace.id], group: group)
        let failure = group == nil ? "Couldn't remove \(workspace.title) from its group" : "Couldn't move \(workspace.title) to \(group?.displayName ?? "")"
        regroup([old].compactMap { $0 }, generation: generation, workspace: workspace, failure: failure) {
            try await grouper.place(workspace, in: group)
        }
    }

    /// Move Workspace to New Group: a new group (the Mac's next color; "New
    /// Group" when no name is given) shows at once with the workspace in it.
    public func moveToNewGroup(_ workspace: Workspace, name: String) {
        guard canGroup(workspace), let grouper else { return }
        let name = MacWorkspaceGroup.chosenName(typed: name)
        let used = Set(grouper.groups(on: workspace.macID).compactMap(\.color))
        let color = MacWorkspaceGroup.nextColor(used: used)
        let pending = MacWorkspaceGroup(id: "pending-\(UUID().uuidString)", name: name, color: color.rawValue)
        let old = store.updateWorkspace(workspace.id) { $0.group = pending }
        // Not held over refreshes (the Mac names the new group with its own
        // id), but it is the workspace's latest edit: earlier ones stop.
        let generation = store.groupEdits.begin([workspace.id], group: pending, holds: false)
        regroup([old].compactMap { $0 }, generation: generation, workspace: workspace, failure: "Couldn't make a group for \(workspace.title)") {
            try await grouper.moveToNewGroup(workspace, name: name, color: color)
        }
    }

    /// Rename Group…: every member shows the new name at once.
    public func renameGroup(_ group: MacWorkspaceGroup, on macID: String, to name: String) {
        guard let name = group.renamed(to: name) else { return }
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

    /// The groups one Mac's rows show on this phone, in the order their first rows show.
    public func shownGroups(on macID: String) -> [MacWorkspaceGroup] {
        #if os(iOS)
        let rows = store.workspaces.filter { $0.macID == macID }
        return workspaceGroupShown(rows: rows.map { WorkspaceGroupShownRow(sidebarIndex: $0.sidebarIndex.map(Int64.init), group: $0.group?.id) })
            .compactMap { rows[Int($0)].group }
        #else
        []
        #endif
    }

    /// Collapse All Groups (true) / Expand All Groups (false) on one Mac.
    public func setAllGroupsCollapsed(on macID: String, _ collapsed: Bool) {
        foldGroups(on: macID, keeping: nil, collapsed)
    }

    /// Collapse Other Groups: every other group of the Mac folds and this one opens (the
    /// Mac's `groupsToggledByCollapsingOthers`).
    public func collapseOtherGroups(keeping group: MacWorkspaceGroup, on macID: String) {
        foldGroups(on: macID, keeping: group.id, true)
    }

    /// The shown groups whose fold Collapse Others (`keeping`) or Collapse / Expand All changes, and to what.
    private func foldChanges(on macID: String, keeping: String?, _ collapsed: Bool) -> [(MacWorkspaceGroup, Bool)] {
        #if os(iOS)
        let shown = shownGroups(on: macID)
        let byID = Dictionary(shown.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return workspaceGroupFoldChanges(shown: shown.map { WorkspaceGroupFold(id: $0.id, collapsed: $0.isCollapsed) },
                                         keeping: keeping, collapsed: collapsed)
            .compactMap { fold in byID[fold.id].map { ($0, fold.collapsed) } }
        #else
        []
        #endif
    }

    private func foldGroups(on macID: String, keeping: String?, _ collapsed: Bool) {
        for (group, fold) in foldChanges(on: macID, keeping: keeping, collapsed) { setGroupCollapsed(group, on: macID, fold) }
    }

    /// Whether Collapse Other Groups would change anything for `group`.
    public func canCollapseOthers(keeping group: MacWorkspaceGroup, on macID: String) -> Bool {
        !foldChanges(on: macID, keeping: group.id, true).isEmpty
    }

    /// The open workspaces of `groups` on one Mac (Close Workspaces in Group, Close Other Groups).
    public func members(of groups: [MacWorkspaceGroup], on macID: String) -> [Workspace] {
        let ids = Set(groups.map(\.id))
        return store.workspaces.filter { $0.macID == macID && !$0.isHome && ($0.group.map { ids.contains($0.id) } ?? false) }
    }

    /// Close Workspaces in Group / Close Other Groups, as the Mac's `closeGroup`: a pinned
    /// group stays, folded and empty; any other group goes; then each workspace closes as Close
    /// Workspace does (the person already said yes).
    public func closeGroups(_ groups: [MacWorkspaceGroup], on macID: String) {
        let members = members(of: groups, on: macID)
        guard let grouper, let first = members.first, members.allSatisfy({ canArrange($0) }) else { return }
        let previous = groupRequestTail[macID]
        let task = track(first.id) { [weak self] in
            await previous?.value
            for group in groups {
                do {
                    if group.isPinned == true {
                        try await grouper.updateGroup(group, on: macID, name: nil, color: nil, collapsed: true)
                    } else {
                        try await grouper.deleteGroup(group, on: macID)
                    }
                } catch {
                    // The group stays: its workspaces stay with it, never an empty group left behind.
                    self?.onManageFailure?(first, "Couldn't close \(group.displayName)", Self.message(error))
                    continue
                }
                self?.close(members.filter { $0.group?.id == group.id })
            }
        }
        groupRequestTail[macID] = task
    }

    private func updateGroup(_ group: MacWorkspaceGroup, on macID: String, failure: String, _ change: (inout MacWorkspaceGroup) -> Void,
                             removes: Bool = false, _ work: @escaping @MainActor (any WorkspaceGroupBackend) async throws -> Void) {
        // The phone shows a group by its members: one of them names the change.
        let members = store.workspaces.filter { $0.macID == macID && $0.group?.id == group.id }
        guard let grouper, let first = members.first, canArrange(first) else { return }
        var changed = group
        change(&changed)
        let old = members.compactMap { ws in store.updateWorkspace(ws.id) { $0.group = removes ? nil : changed } }
        let generation = store.groupEdits.begin(old.map(\.id), group: removes ? nil : changed)
        regroup(old, generation: generation, workspace: first, failure: failure) { try await work(grouper) }
    }

    /// Sends a group edit already shown, after the Mac's earlier group
    /// requests. `generation` (`PendingGroupEdits`) holds it over refreshes;
    /// a refusal rolls back only the workspaces whose latest edit it still is.
    private func regroup(_ old: [Workspace], generation: Int, workspace: Workspace, failure: String,
                         _ work: @escaping @MainActor () async throws -> Void) {
        let ids = old.map(\.id)
        let macID = workspace.macID
        let previous = groupRequestTail[macID]
        let task = track(workspace.id) { [weak self] in
            await previous?.value
            self?.store.groupEdits.sent(ids, generation: generation, at: self?.store.now() ?? Date())
            do {
                try await work()
                guard let self else { return }
                store.groupEdits.answered(ids, generation: generation, at: store.now())
            } catch {
                guard let self else { return }
                let latest = store.groupEdits.refused(ids, generation: generation)
                for ws in old where latest.contains(ws.id) { store.updateWorkspace(ws.id) { $0.group = ws.group } }
                onManageFailure?(workspace, failure, Self.message(error))
            }
        }
        groupRequestTail[macID] = task
    }
}

#if DEBUG
/// Mock mode: every group change is accepted after the mock latency; no groups to list.
extension MockWorkspaceCreationBackend: WorkspaceGroupBackend {
    public func groups(on macID: String) -> [MacWorkspaceGroup] { [] }
    public func place(_ workspace: Workspace, in group: MacWorkspaceGroup?) async throws { try await rename(workspace, to: workspace.title) }
    public func moveToNewGroup(_ workspace: Workspace, name: String, color: WorkspaceColor) async throws { try await rename(workspace, to: workspace.title) }
    public func createGroup(named name: String, color: WorkspaceColor, on macID: String) async throws -> MacWorkspaceGroup {
        MacWorkspaceGroup(id: "mock-\(UUID().uuidString)", name: name, color: color.rawValue)
    }
    public func updateGroup(_ group: MacWorkspaceGroup, on macID: String, name: String?, color: WorkspaceColor?, collapsed: Bool?) async throws {}
    public func deleteGroup(_ group: MacWorkspaceGroup, on macID: String) async throws {}
}
#endif
