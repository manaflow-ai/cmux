public import CmuxHomeCore

/// What the group info sheet's controls do: closures over the app's one path
/// (`HomeGroupActions`, and the registry for Leave so it asks first), so the sheet holds no store.
public struct HomeGroupInfoActions {
    /// Rename the group (the new name, trimmed by the owner path).
    public var rename: @MainActor (String) async -> HomeGroupOutcome
    /// Add these people (ids, and their names for a refusal).
    public var add: @MainActor ([ParticipantID], String) async -> HomeGroupOutcome
    /// Remove this member.
    public var remove: @MainActor (ParticipantID) async -> HomeGroupOutcome
    /// Hide Alerts (`true`) or Show Alerts.
    public var setMuted: @MainActor (Bool) -> HomeGroupOutcome
    /// Leave Group…: the sheet has closed; the action asks, then leaves.
    public var leave: @MainActor () -> Void
    /// Set when the group's Chiefs answer (the Chiefs Reply row).
    public var setChiefReplies: @MainActor (ChiefReplyPolicy) async -> HomeGroupOutcome
    /// Invite by Email… after a `not_reachable` refusal: the sheet has closed.
    public var inviteByEmail: @MainActor () -> Void

    public init(rename: @escaping @MainActor (String) async -> HomeGroupOutcome,
                add: @escaping @MainActor ([ParticipantID], String) async -> HomeGroupOutcome,
                remove: @escaping @MainActor (ParticipantID) async -> HomeGroupOutcome,
                setMuted: @escaping @MainActor (Bool) -> HomeGroupOutcome,
                leave: @escaping @MainActor () -> Void,
                inviteByEmail: @escaping @MainActor () -> Void,
                setChiefReplies: @escaping @MainActor (ChiefReplyPolicy) async -> HomeGroupOutcome) {
        self.rename = rename
        self.add = add
        self.remove = remove
        self.setMuted = setMuted
        self.leave = leave
        self.inviteByEmail = inviteByEmail
        self.setChiefReplies = setChiefReplies
    }
}
