/// Captured account/team owner for async scoped loads.
///
/// A load may suspend while the user switches teams; publishing is allowed only
/// if this snapshot still matches when the await returns.
struct MobileShellScopeSnapshot: Equatable, Sendable {
    let userID: String
    let teamID: String?
    let generation: Int
}
