public import CmuxNextDaemon

/// When a personal workspace group ends (cx-rcby), over the home session's
/// personal `groups` and `rows`. The home daemon keeps a group until a
/// client deletes it, so the client that moves or closes workspaces owns the rule:
/// - an unpinned group that loses its last live member is deleted (the
///   daemon records the delete in closed history, so Reopen Closed brings it
///   back); a pinned (saved) group stays empty;
/// - New Group on workspaces that already are one whole group makes no
///   second group;
/// - a group made with no member is deleted when its name editor closes
///   while it is still empty.
/// "Live" members are the rows the sidebar can show: a closed workspace
/// keeps its personal row (reopen restores its group) but holds no group open.
public struct PersonalGroupLifecycle: Sendable {
    /// A session-qualified workspace, the personal rows' key.
    public struct Member: Hashable, Sendable {
        public var session: String
        public var key: String

        public init(session: String, key: String) {
            self.session = session
            self.key = key
        }
    }

    public struct Group: Sendable {
        public var id: WorkspaceGroupID
        public var pinned: Bool

        public init(id: WorkspaceGroupID, pinned: Bool) {
            self.id = id
            self.pinned = pinned
        }
    }

    public var groups: [Group]
    public var rows: [PersonalWorkspace]

    public init(groups: [Group], rows: [PersonalWorkspace]) {
        self.groups = groups
        self.rows = rows
    }

    public static func member(_ row: PersonalWorkspace) -> Member {
        Member(session: row.sessionID, key: row.workspaceKey.rawValue)
    }

    /// The unpinned groups that `leaving` leaves with no live member when
    /// they move to `target` (nil: loose, or a new group).
    public func emptied(leaving: Set<Member>, into target: WorkspaceGroupID?, isLive: (Member) -> Bool) -> [WorkspaceGroupID] {
        let sources = Set(rows.filter { leaving.contains(Self.member($0)) }.compactMap(\.group))
        return groups.filter { group in
            !group.pinned && group.id != target && sources.contains(group.id)
                && !rows.contains { $0.group == group.id && !leaving.contains(Self.member($0)) && isLive(Self.member($0)) }
        }.map(\.id)
    }

    /// The group whose live members are exactly `members`, if any.
    public func whole(members: Set<Member>, isLive: (Member) -> Bool) -> WorkspaceGroupID? {
        guard !members.isEmpty else { return nil }
        return groups.first { group in
            Set(rows.filter { $0.group == group.id }.map(Self.member).filter(isLive)) == members
        }?.id
    }

    /// Whether `group` has no live member.
    public func isEmpty(_ group: WorkspaceGroupID, isLive: (Member) -> Bool) -> Bool {
        !rows.contains { $0.group == group && isLive(Self.member($0)) }
    }

    /// The groups of closing workspaces that their close may delete: unpinned ones only,
    /// since a pinned (saved) group stays when its last workspace closes.
    public func prunable(_ closing: Set<WorkspaceGroupID>) -> Set<WorkspaceGroupID> {
        closing.filter { id in groups.contains { $0.id == id && !$0.pinned } }
    }
}
