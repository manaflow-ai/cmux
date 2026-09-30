/// A pure snapshot of every prerequisite for presenting the migration notice.
struct MobileAutoConnectMigrationReadiness: Equatable, Sendable {
    let hasPendingMigration: Bool
    let hasCompletedOnboarding: Bool
    let isAuthenticated: Bool
    let isRestoringAuthentication: Bool
    let isSceneActive: Bool
    let hasExplicitAttachRoute: Bool

    /// Whether the notice may compete for the shared modal slot now.
    var canPresent: Bool {
        hasPendingMigration
            && hasCompletedOnboarding
            && isAuthenticated
            && !isRestoringAuthentication
            && isSceneActive
            && !hasExplicitAttachRoute
    }
}
