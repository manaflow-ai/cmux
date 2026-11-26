/// A team create still waiting on the server, shown as the active team until
/// the server answers.
struct PendingTeamCreate: Equatable {
    let displayName: String
    /// Teams listed when the create started. The coordinator lists the new team
    /// before it finishes selecting it, and the pending entry stands for that
    /// team until then, so no surface shows it twice.
    let existingTeamIDs: Set<String>
}
