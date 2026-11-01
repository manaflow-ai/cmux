import Foundation

/// The Mac's workspace colors (cmux-next `GroupColor`): the palette names its
/// Set Workspace Color… menu offers and `set-workspace-metadata` stores.
public enum WorkspaceColor: String, CaseIterable, Hashable, Sendable {
    case grey, blue, red, yellow, green, pink, purple, cyan, orange

    /// The Mac's menu name ("Grey", "Blue", …).
    public var title: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }

    /// Hue in degrees and relative chroma, as the Mac draws its swatch.
    public var hueAndChroma: (hue: Double, chroma: Double) {
        switch self {
        case .grey: (0, 0)
        case .blue: (214, 1)
        case .red: (4, 1)
        case .yellow: (46, 1)
        case .green: (136, 0.9)
        case .pink: (330, 0.95)
        case .purple: (272, 0.9)
        case .cyan: (186, 0.9)
        case .orange: (24, 1)
        }
    }

    /// A stored color value: a palette name, or nil (`#RRGGBB` colors are not in the menu).
    public init?(stored: String?) {
        guard let stored, let color = WorkspaceColor(rawValue: stored.lowercased()) else { return nil }
        self = color
    }
}

/// What the Mac's sidebar knows about its workspaces beyond the tree: the
/// person's own order (`list-personal`) and their pinned tiles
/// (`sidebar_layout.get`, section `sec_pinned`). Either may be missing (an
/// older Mac): then the daemon's workspace order and the legacy pin flag count.
public struct SidebarArrangement: Equatable, Sendable {
    /// One personal sidebar row (`list-personal.workspaces[]`).
    public struct Row: Equatable, Sendable {
        public var session: String
        public var key: String
        public var index: Int
        /// Its personal group (`group`), if any.
        public var group: String?

        public init(session: String, key: String, index: Int, group: String? = nil) {
            self.session = session
            self.key = key
            self.index = index
            self.group = group
        }
    }

    /// One pinned tile: its layout item id and its ref value (`<session>:<ws_…>`).
    public struct Pin: Equatable, Sendable {
        public var itemID: String
        public var value: String

        public init(itemID: String, value: String) {
            self.itemID = itemID
            self.value = value
        }
    }

    /// Personal rows of every session (nil: the Mac has no personal order).
    public var rows: [Row]?
    /// Pinned tiles in order (nil: the Mac has no sidebar layout; the legacy flag counts).
    public var pins: [Pin]?
    /// The person's workspace groups (`list-personal.groups`); empty on a Mac without them.
    public var groups: [MacWorkspaceGroup]
    /// Rooms (`list-personal.profiles`) and workspaces pinned to one
    /// (`list-personal.pins`): the room a new group of a workspace goes to.
    public var rooms: [Room]
    public var roomPins: [RoomPin]

    public init(rows: [Row]? = nil, pins: [Pin]? = nil, groups: [MacWorkspaceGroup] = [], rooms: [Room] = [], roomPins: [RoomPin] = []) {
        self.rows = rows
        self.pins = pins
        self.groups = groups
        self.rooms = rooms
        self.roomPins = roomPins
    }

    public static let pinnedSectionID = "sec_pinned"

    /// Parses `list-personal` (`{"ok":true,"data":{"workspaces":[…]}}` or bare data).
    public static func rows(personal reply: [String: Any]) -> [Row]? {
        let data = reply["data"] as? [String: Any] ?? reply
        guard let list = data["workspaces"] as? [[String: Any]] else { return nil }
        return list.compactMap { row in
            guard let session = row["session_id"] as? String, let key = row["workspace_key"] as? String else { return nil }
            return Row(session: session, key: key, index: row["index"] as? Int ?? 0, group: row["group"] as? String)
        }
    }

    /// Parses a `sidebar_layout.get` response (`result` is the layout snapshot).
    public static func pins(layout reply: [String: Any]) -> [Pin]? {
        let snapshot = reply["result"] as? [String: Any] ?? reply
        guard let sections = snapshot["sections"] as? [[String: Any]] else { return nil }
        guard let pinned = sections.first(where: { $0["id"] as? String == pinnedSectionID }) else { return [] }
        return (pinned["items"] as? [[String: Any]] ?? []).compactMap { item in
            guard let id = item["id"] as? String, let ref = item["ref"] as? [String: Any],
                  ref["kind"] as? String == "workspace", let value = ref["value"] as? String else { return nil }
            return Pin(itemID: id, value: value)
        }
    }

    /// The layout ref value of a workspace of session `registryID`.
    public static func refValue(registryID: String, resourceID: String) -> String { "\(registryID):\(resourceID)" }

    /// Sets each workspace's pin and sidebar place. `workspaces` are in the
    /// daemon's order; `legacyPinned` holds the ids the daemon flags pinned.
    public func apply(to workspaces: inout [Workspace], registryID: String?, legacyPinned: Set<String>) {
        let pinIndex: [String: (Int, String)] = Dictionary(
            (pins ?? []).enumerated().map { ($1.value, ($0, $1.itemID)) }, uniquingKeysWith: { first, _ in first })
        // Every session's rows in personal order; this session's keys by place.
        let ordered = (rows ?? []).sorted { $0.index < $1.index }
        let place: [String: Int] = Dictionary(
            ordered.enumerated().compactMap { offset, row in row.session == registryID ? (row.key, offset) : nil },
            uniquingKeysWith: { first, _ in first })
        let rowCount = ordered.count
        for i in workspaces.indices {
            let ws = workspaces[i]
            let ref = registryID.flatMap { id in ws.resourceID.map { Self.refValue(registryID: id, resourceID: $0) } }
            if let pins {
                // A flagged workspace the Mac has not turned into its tile yet shows pinned too.
                let pin = ref.flatMap { pinIndex[$0] }
                let flagged = legacyPinned.contains(ws.id)
                workspaces[i].isPinned = pin != nil || flagged
                workspaces[i].pinIndex = pin?.0 ?? (flagged ? pins.count + i : nil)
                workspaces[i].pinItemID = pin?.1
            } else {
                workspaces[i].isPinned = legacyPinned.contains(ws.id)
                workspaces[i].pinIndex = workspaces[i].isPinned ? i : nil
                workspaces[i].pinItemID = nil
            }
            // Rowed workspaces by personal place, then the rest in daemon order (the Mac's `order`).
            workspaces[i].sidebarIndex = rows == nil ? i : (place[ws.id] ?? rowCount + i)
            workspaces[i].group = nil
        }
        if let registryID, rows != nil, !groups.isEmpty { applyGroups(to: &workspaces, registryID: registryID) }
    }

    /// Where Move Up / Down puts `workspace` among `visible` (the Mac's sidebar
    /// order, pinned tiles left out), as the Mac's `movePersonalWorkspace`: the
    /// personal index next to its neighbour. Nil at either end, or when the
    /// neighbour has no personal row.
    public func personalIndex(moving workspace: Workspace, by offset: Int, among visible: [Workspace],
                              registryID: String) -> Int? {
        guard let rows, let position = visible.firstIndex(where: { $0.id == workspace.id }),
              visible.indices.contains(position + offset) else { return nil }
        let anchor = visible[position + offset]
        let order = rows.sorted { $0.index < $1.index }.map { "\($0.session)/\($0.key)" }
            .filter { $0 != "\(registryID)/\(workspace.id)" }
        guard let anchorIndex = order.firstIndex(of: "\(registryID)/\(anchor.id)") else { return nil }
        return offset > 0 ? anchorIndex + 1 : anchorIndex
    }

    /// The personal index that puts `workspace` right before (`after` false) or right after
    /// `anchor` (Move Workspace to Top / to Bottom, each step of Sort Workspaces): the anchor's
    /// place in the person's order without the workspace. Nil when either has no personal row.
    public func personalIndex(placing workspace: Workspace, next anchor: Workspace, after: Bool, registryID: String) -> Int? {
        guard let rows, anchor.id != workspace.id else { return nil }
        let order = rows.sorted { $0.index < $1.index }.map { "\($0.session)/\($0.key)" }
        let without = order.filter { $0 != "\(registryID)/\(workspace.id)" }
        guard let anchorIndex = without.firstIndex(of: "\(registryID)/\(anchor.id)") else { return nil }
        return after ? anchorIndex + 1 : anchorIndex
    }
}

/// Move Workspace to Top / to Bottom: the first or last place of the workspace's own
/// container (its group, else the loose rows), as the Mac's `WorkspaceSlot.top` / `.bottom`.
public enum WorkspaceEdge: String, CaseIterable, Hashable, Sendable {
    case top, bottom

    /// The Mac's titles (`action.palette.moveWorkspaceToTop`, `action.workspace.moveToBottom`;
    /// a grouped row's menu says "of Group", `WorkspaceVerbStrings.moveToTopOfGroup`).
    public func title(grouped: Bool) -> String {
        switch (self, grouped) {
        case (.top, false): "Move Workspace to Top"
        case (.bottom, false): "Move Workspace to Bottom"
        case (.top, true): "Move to Top of Group"
        case (.bottom, true): "Move to Bottom of Group"
        }
    }

    /// The row the workspace goes next to in `order` (its container, in the Mac's order), and
    /// on which side; nil when it is already there.
    public func anchor(of workspace: Workspace, in order: [Workspace]) -> (anchor: Workspace, after: Bool)? {
        guard order.contains(where: { $0.id == workspace.id }) else { return nil }
        switch self {
        case .top:
            guard let first = order.first, first.id != workspace.id else { return nil }
            return (first, false)
        case .bottom:
            guard let last = order.last, last.id != workspace.id else { return nil }
            return (last, true)
        }
    }
}

/// Sort Workspaces by Name / Last Used / Directory (the Mac's `WorkspaceSortKey`): every
/// container of one Mac's sidebar (its loose rows, each group's members) sorted in place;
/// pinned rows keep their own order (the Mac's pinned section is not sorted).
public enum WorkspaceSortKey: String, CaseIterable, Hashable, Sendable {
    case name, lastUsed, directory

    /// The Mac's titles (`action.workspace.sortBy…`).
    public var title: String {
        switch self {
        case .name: "Sort Workspaces by Name"
        case .lastUsed: "Sort Workspaces by Last Used"
        case .directory: "Sort Workspaces by Directory"
        }
    }

    /// The short row title inside the phone's Sort folder.
    public var shortTitle: String {
        switch self {
        case .name: "By Name"
        case .lastUsed: "By Last Used"
        case .directory: "By Directory"
        }
    }

    public var systemImage: String {
        switch self {
        case .name: "textformat.abc"
        case .lastUsed: "clock"
        case .directory: "folder"
        }
    }

    /// `workspaces` (one container, in its current order) sorted by this key, as the Mac
    /// sorts: `name` in Finder order; `directory` by folder, then name, rows without one
    /// last; `lastUsed` most recently focused first (the daemon's focus order: a phone can't
    /// see a Mac window's own recency), ties in their current order.
    public func sorted(_ workspaces: [Workspace]) -> [Workspace] {
        let position = Dictionary(workspaces.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        func byName(_ lhs: Workspace, _ rhs: Workspace) -> Bool {
            let order = lhs.title.localizedStandardCompare(rhs.title)
            return order == .orderedSame ? position[lhs.id, default: 0] < position[rhs.id, default: 0] : order == .orderedAscending
        }
        switch self {
        case .name:
            return workspaces.sorted(by: byName)
        case .directory:
            return workspaces.sorted { lhs, rhs in
                let (l, r) = (lhs.directory.isEmpty ? nil : lhs.directory, rhs.directory.isEmpty ? nil : rhs.directory)
                switch (l, r) {
                case let (l?, r?) where l != r: return l.localizedStandardCompare(r) == .orderedAscending
                case (_?, nil): return true
                case (nil, _?): return false
                default: return byName(lhs, rhs)
                }
            }
        case .lastUsed:
            return workspaces.sorted { lhs, rhs in
                if lhs.hasActivityTime != rhs.hasActivityTime { return lhs.hasActivityTime }
                if lhs.hasActivityTime, lhs.lastActivityAt != rhs.lastActivityAt { return lhs.lastActivityAt > rhs.lastActivityAt }
                if lhs.focusOrder != rhs.focusOrder { return lhs.focusOrder > rhs.focusOrder }
                return position[lhs.id, default: 0] < position[rhs.id, default: 0]
            }
        }
    }

    /// The moves that turn `order` (one container) into `sorted`, one row at a time as the Mac
    /// places them: the first row before the container's current first row, each next one right
    /// after the one before it. Rows already in place are not moved.
    public static func steps(from order: [Workspace], to sorted: [Workspace]) -> [(workspace: Workspace, anchor: Workspace, after: Bool)] {
        var current = order
        var steps: [(Workspace, Workspace, Bool)] = []
        for (offset, workspace) in sorted.enumerated() {
            guard let at = current.firstIndex(where: { $0.id == workspace.id }), at != offset else { continue }
            let anchor = offset == 0 ? current[0] : sorted[offset - 1]
            steps.append((workspace, anchor, offset != 0))
            current.remove(at: at)
            current.insert(workspace, at: offset)
        }
        return steps
    }
}

/// Pin, color, order and read marks of workspaces on their Mac (the Mac's
/// sidebar row menu), for a backend that can change them.
@MainActor
public protocol WorkspaceArrangementBackend: AnyObject {
    func canArrange(on macID: String) -> Bool
    /// Pin Workspace / Unpin Workspace.
    func setPinned(_ workspace: Workspace, _ pinned: Bool) async throws
    /// Set Workspace Color… (a palette name) / Reset Workspace Color (nil).
    func setColor(_ workspace: Workspace, _ color: WorkspaceColor?) async throws
    /// Move Workspace Up (-1) / Down (+1) among `visible`, the Mac's sidebar order.
    func move(_ workspace: Workspace, by offset: Int, among visible: [Workspace]) async throws
    /// Mark Workspace as Read (false) / as Unread (true).
    func setUnread(_ workspace: Workspace, _ unread: Bool) async throws
    /// Set Icon… (an SF Symbol name or one emoji) / Remove Icon (nil).
    func setIcon(_ workspace: Workspace, _ icon: String?) async throws
    /// Clear Workspace Name: the display name goes; the workspace's own name shows.
    func clearName(_ workspace: Workspace) async throws
    /// Puts `workspace` right before or after `anchor` in the Mac's sidebar order (Move
    /// Workspace to Top / to Bottom, Sort Workspaces).
    func place(_ workspace: Workspace, next anchor: Workspace, after: Bool) async throws
}

/// Workspace icons the phone offers: SF Symbols both the Mac and the phone draw
/// (the Mac stores the symbol name), or one emoji typed by the person.
public enum WorkspaceIcon {
    public static let symbols = ["folder", "terminal", "globe", "star", "flame", "bolt", "hammer", "ladybug",
                                 "book", "sparkles", "leaf", "heart", "cube", "gearshape", "doc.text", "server.rack"]

    /// One emoji (one character with emoji presentation), as the Mac's icon check takes it.
    public static func emoji(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count == 1, let first = trimmed.unicodeScalars.first,
              first.properties.isEmojiPresentation || (first.properties.isEmoji && trimmed.unicodeScalars.count > 1) else { return nil }
        return trimmed
    }
}

/// Clear All Notifications on a Mac (its notification ledger).
@MainActor
public protocol NotificationClearing: AnyObject {
    func canClearNotifications(on macID: String) -> Bool
    func clearAllNotifications(on macID: String) async throws
    /// Mark All Notifications as Read: every tab the Mac shows unread is read
    /// (`ack-tab-notifications`); returns how many.
    func markAllNotificationsRead(on macID: String) async throws -> Int
}

extension NotificationClearing {
    public func markAllNotificationsRead(on macID: String) async throws -> Int { 0 }
}

extension AppStore {
    /// Changes one workspace in place and returns its previous value (for a rollback).
    @discardableResult
    public func updateWorkspace(_ workspaceID: String, _ change: (inout Workspace) -> Void) -> Workspace? {
        let workspaceID = resolvedWorkspaceID(workspaceID)
        guard let index = workspaces.firstIndex(where: { $0.id == workspaceID }) else { return nil }
        let old = workspaces[index]
        change(&workspaces[index])
        return old
    }
}

extension WorkspaceCreator {
    var arranger: (any WorkspaceArrangementBackend)? { backend as? any WorkspaceArrangementBackend }

    /// Whether the workspace's pin, color, order and read mark can change from here now.
    public func canArrange(_ workspace: Workspace) -> Bool {
        guard canManage(workspace), let arranger else { return false }
        return arranger.canArrange(on: workspace.macID)
    }

    /// Pin Workspace / Unpin Workspace: at once on the phone, undone if the Mac refuses.
    public func setPinned(_ workspace: Workspace, _ pinned: Bool) {
        guard canArrange(workspace), workspace.isPinned != pinned, let arranger else { return }
        let pinIndex = (store.workspaces.compactMap(\.pinIndex).max() ?? -1) + 1
        let old = store.updateWorkspace(workspace.id) {
            $0.isPinned = pinned
            $0.pinIndex = pinned ? pinIndex : nil
        }
        arrange(workspace, old: old, failure: pinned ? "Couldn't pin \(workspace.title)" : "Couldn't unpin \(workspace.title)") {
            try await arranger.setPinned(workspace, pinned)
        }
    }

    /// Set Workspace Color… / Reset Workspace Color.
    public func setColor(_ workspace: Workspace, _ color: WorkspaceColor?) {
        guard canArrange(workspace), let arranger else { return }
        let old = store.updateWorkspace(workspace.id) { $0.colorHex = color?.rawValue }
        arrange(workspace, old: old, failure: "Couldn't change the color of \(workspace.title)") {
            try await arranger.setColor(workspace, color)
        }
    }

    /// Mark Workspace as Read / as Unread.
    public func setUnread(_ workspace: Workspace, _ unread: Bool) {
        guard canArrange(workspace), let arranger else { return }
        let old = store.updateWorkspace(workspace.id) { $0.hasUnread = unread }
        if !unread { store.markSeen(workspace.id) }
        arrange(workspace, old: old, failure: unread ? "Couldn't mark \(workspace.title) as unread" : "Couldn't mark \(workspace.title) as read") {
            try await arranger.setUnread(workspace, unread)
        }
    }

    /// Set Icon… / Remove Icon.
    public func setIcon(_ workspace: Workspace, _ icon: String?) {
        guard canArrange(workspace), let arranger else { return }
        let old = store.updateWorkspace(workspace.id) { $0.icon = icon }
        arrange(workspace, old: old, failure: "Couldn't change the icon of \(workspace.title)") {
            try await arranger.setIcon(workspace, icon)
        }
    }

    /// Clear Workspace Name: the Mac's own name comes back with its next list.
    public func clearName(_ workspace: Workspace) {
        guard canArrange(workspace), workspace.hasCustomTitle, let arranger else { return }
        let old = store.updateWorkspace(workspace.id) { $0.hasCustomTitle = false }
        arrange(workspace, old: old, failure: "Couldn't clear the name of \(workspace.title)") {
            try await arranger.clearName(workspace)
        }
    }

    /// Move Workspace Up (-1) / Down (+1) among `visible` (the list's own
    /// section in the Mac's order). The phone swaps the places at once; the
    /// Mac's answer settles them.
    public func move(_ workspace: Workspace, by offset: Int, among visible: [Workspace]) {
        guard canArrange(workspace), !workspace.isPinned, let arranger,
              let position = visible.firstIndex(where: { $0.id == workspace.id }),
              visible.indices.contains(position + offset) else { return }
        let neighbour = visible[position + offset]
        let (mine, theirs) = (workspace.sidebarIndex ?? position, neighbour.sidebarIndex ?? position + offset)
        let old = store.updateWorkspace(workspace.id) { $0.sidebarIndex = theirs }
        let oldNeighbour = store.updateWorkspace(neighbour.id) { $0.sidebarIndex = mine }
        track(workspace.id) { [weak self] in
            do {
                try await arranger.move(workspace, by: offset, among: visible)
            } catch {
                if let old { self?.store.updateWorkspace(old.id) { $0.sidebarIndex = old.sidebarIndex } }
                if let oldNeighbour { self?.store.updateWorkspace(oldNeighbour.id) { $0.sidebarIndex = oldNeighbour.sidebarIndex } }
                self?.onManageFailure?(workspace, "Couldn't move \(workspace.title)", Self.message(error))
            }
        }
    }

    /// Close Other Workspaces / Close Workspaces Above / Below: each as Close Workspace.
    public func close(_ workspaces: [Workspace]) {
        for workspace in workspaces { close(workspace) }
    }

    /// One Mac's unpinned rows of `workspace`'s container (its group, else the loose rows) in
    /// the Mac's sidebar order: what Move Workspace to Top / to Bottom moves among. Empty for a
    /// pinned workspace (the Mac orders its pinned tiles with a layout move a phone may not send).
    public func container(of workspace: Workspace) -> [Workspace] {
        guard !workspace.isPinned else { return [] }
        return containers(on: workspace.macID).first { $0.first?.group?.id == workspace.group?.id }
            .flatMap { $0.contains { $0.id == workspace.id } ? $0 : nil } ?? []
    }

    /// Every container of one Mac's sidebar this phone may arrange (the loose rows, then each
    /// group's members), each in the Mac's order; pinned rows, Home and rows still being made
    /// are left out.
    public func containers(on macID: String) -> [[Workspace]] {
        let rows = store.workspaces
            .filter { $0.macID == macID && !$0.isPinned && !$0.isHome && canArrange($0) }
            .enumerated()
            .sorted { ($0.element.sidebarIndex ?? Int.max, $0.offset) < ($1.element.sidebarIndex ?? Int.max, $1.offset) }
            .map(\.element)
        var order: [String?] = []
        var byGroup: [String?: [Workspace]] = [:]
        for row in rows {
            let key = row.group?.id
            if byGroup[key] == nil { order.append(key) }
            byGroup[key, default: []].append(row)
        }
        // The loose rows first, then the groups in the order their first rows show.
        return ([nil] + order.filter { $0 != nil }).compactMap { byGroup[$0] }
    }

    /// Move Workspace to Top / to Bottom of its container. The list shows the new place at
    /// once; the Mac's answer settles it.
    public func move(_ workspace: Workspace, to edge: WorkspaceEdge) {
        let order = container(of: workspace)
        guard canArrange(workspace), let arranger, let target = edge.anchor(of: workspace, in: order) else { return }
        let (anchor, after) = (target.anchor, target.after)
        let old = reorderLocally(order, to: edge == .top ? [workspace] + order.filter { $0.id != workspace.id }
            : order.filter { $0.id != workspace.id } + [workspace])
        track(workspace.id) { [weak self] in
            do {
                try await arranger.place(workspace, next: anchor, after: after)
            } catch {
                self?.restore(old)
                self?.onManageFailure?(workspace, "Couldn't move \(workspace.title)", Self.message(error))
            }
        }
    }

    /// Sort Workspaces by Name / Last Used / Directory on one Mac: every container sorted in
    /// place, shown at once; the Mac's rows move one at a time, as the Mac's own sort moves them.
    public func sortWorkspaces(on macID: String, by key: WorkspaceSortKey) {
        guard let arranger else { return }
        let plans = containers(on: macID).map { order in (order, key.sorted(order)) }.filter { $0.0.map(\.id) != $0.1.map(\.id) }
        guard !plans.isEmpty, let first = plans.first?.0.first else { return }
        let old = plans.flatMap { reorderLocally($0.0, to: $0.1) }
        track("sort-\(macID)") { [weak self] in
            var moved = false
            do {
                for (order, sorted) in plans {
                    for step in WorkspaceSortKey.steps(from: order, to: sorted) {
                        try await arranger.place(step.workspace, next: step.anchor, after: step.after)
                        moved = true
                    }
                }
            } catch {
                // Nothing moved: the old places come back. Some moved: the Mac's list (already
                // read after each move) is the truth, so nothing is put back over it.
                if !moved { self?.restore(old) }
                self?.onManageFailure?(first, "Couldn't sort the workspaces", Self.message(error))
            }
        }
    }

    /// Remove All Workspace Colors on one Mac: every workspace there loses its color at once,
    /// each through the same change as its own Reset Workspace Color. The Mac's group colors
    /// stay: a phone may set a group only to one of the Mac's nine colors, not to none.
    public func removeAllColors(on macID: String) {
        for workspace in store.workspaces where workspace.macID == macID && workspace.colorHex != nil && canArrange(workspace) {
            setColor(workspace, nil)
        }
    }

    /// Whether Remove All Workspace Colors has a workspace to change on `macID`.
    public func hasColors(on macID: String) -> Bool {
        store.workspaces.contains { $0.macID == macID && $0.colorHex != nil && canArrange($0) }
    }

    /// Gives `order`'s rows the places of `sorted` (the same rows) and returns their old values.
    private func reorderLocally(_ order: [Workspace], to sorted: [Workspace]) -> [Workspace] {
        let places = order.enumerated().map { $1.sidebarIndex ?? $0 }
        return zip(sorted, places).compactMap { workspace, place in store.updateWorkspace(workspace.id) { $0.sidebarIndex = place } }
    }

    private func restore(_ old: [Workspace]) {
        for workspace in old { store.updateWorkspace(workspace.id) { $0.sidebarIndex = workspace.sidebarIndex } }
    }

    private func arrange(_ workspace: Workspace, old: Workspace?, failure: String, _ work: @escaping @MainActor () async throws -> Void) {
        track(workspace.id) { [weak self] in
            do {
                try await work()
            } catch {
                if let old { self?.store.updateWorkspace(old.id) { $0 = old } }
                self?.onManageFailure?(workspace, failure, Self.message(error))
            }
        }
    }
}

/// Close Other Workspaces / Above / Below, as the Mac's palette names them,
/// over the Mac's sidebar order of one Mac's workspaces.
public enum WorkspaceBulkClose: String, CaseIterable, Hashable, Sendable {
    case others, above, below
    /// Close Other Workspaces in Group: the row's group's other workspaces.
    case othersInGroup
    /// Close All Workspaces: every workspace of the Mac (never Home).
    case all

    /// The Mac's titles.
    public var title: String {
        switch self {
        case .others: "Close Other Workspaces"
        case .above: "Close Workspaces Above"
        case .below: "Close Workspaces Below"
        case .othersInGroup: "Close Other Workspaces in Group"
        case .all: "Close All Workspaces"
        }
    }

    /// The workspaces this closes when chosen on `workspace`, in `order`. Home never closes
    /// (the Mac's `HomeRules`).
    public func targets(of workspace: Workspace, in order: [Workspace]) -> [Workspace] {
        guard let index = order.firstIndex(where: { $0.id == workspace.id }) else { return [] }
        let targets: [Workspace] = switch self {
        case .others: order.filter { $0.id != workspace.id }
        case .above: Array(order[..<index])
        case .below: Array(order[(index + 1)...])
        case .othersInGroup:
            workspace.group.map { group in order.filter { $0.id != workspace.id && $0.group?.id == group.id } } ?? []
        case .all: order
        }
        return targets.filter { !$0.isHome }
    }

    /// "Close 3 workspaces?" (the phone asks first; the Mac closes at once).
    public static func question(_ count: Int) -> String {
        count == 1 ? "Close 1 workspace?" : "Close \(count) workspaces?"
    }
}

#if DEBUG
/// Mock mode: every arrangement change is accepted after the mock latency.
extension MockWorkspaceCreationBackend: WorkspaceArrangementBackend, NotificationClearing {
    public func canArrange(on macID: String) -> Bool { true }
    public func setPinned(_ workspace: Workspace, _ pinned: Bool) async throws { try await rename(workspace, to: workspace.title) }
    public func setColor(_ workspace: Workspace, _ color: WorkspaceColor?) async throws { try await rename(workspace, to: workspace.title) }
    public func move(_ workspace: Workspace, by offset: Int, among visible: [Workspace]) async throws { try await rename(workspace, to: workspace.title) }
    public func setUnread(_ workspace: Workspace, _ unread: Bool) async throws { try await rename(workspace, to: workspace.title) }
    public func setIcon(_ workspace: Workspace, _ icon: String?) async throws { try await rename(workspace, to: workspace.title) }
    public func clearName(_ workspace: Workspace) async throws { try await rename(workspace, to: workspace.title) }
    public func place(_ workspace: Workspace, next anchor: Workspace, after: Bool) async throws { try await rename(workspace, to: workspace.title) }
    public func canClearNotifications(on macID: String) -> Bool { true }
    public func clearAllNotifications(on macID: String) async throws {}
}
#endif

/// A folder the person types for New Workspace › Open Folder…: a full path
/// on the Mac (`/…`, `~` or `~/…`). The new workspace's terminal changes to it
/// with a typed `cd`, so a folder whose name a shell's line editor would act
/// on (control or format characters, DEL, a backslash, `!`) is never typed
/// (cmux-next-ios/SECURITY.md "Parity with the Mac app's tab and workspace actions").
public struct WorkspaceFolderPath: Hashable, Sendable {
    public let path: String

    /// Nil for an empty field.
    public init?(_ text: String) {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.count > 1, trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard !trimmed.isEmpty else { return nil }
        path = trimmed
    }

    /// Why this folder can't be opened from the phone, or nil.
    public func refusal(macName: String) -> String? {
        guard path == "~" || path.hasPrefix("~/") || path.hasPrefix("/") else {
            return "Type the folder's full path on \(macName), starting with / or ~/."
        }
        guard Self.isTypable(path) else {
            return "This folder's name has a character a phone never types into a terminal (a backslash, !, or a control character). Open it in cmux on \(macName)."
        }
        return nil
    }

    /// No character a shell's line editor acts on inside quotes.
    public static func isTypable(_ path: String) -> Bool {
        !path.unicodeScalars.contains { scalar in
            let category = scalar.properties.generalCategory
            return category == .control || category == .format || category == .lineSeparator || category == .paragraphSeparator
                || scalar == "\\" || scalar == "!" || scalar.value == 0x7f
        }
    }
}
