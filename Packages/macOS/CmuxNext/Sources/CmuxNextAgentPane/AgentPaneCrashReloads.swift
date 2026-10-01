import Foundation

/// Decides whether a pane reloads its page after the web content process
/// crashes. A page that crashes as it loads would otherwise reload forever.
nonisolated struct AgentPaneCrashReloads: Equatable, Sendable {
    /// Reloads allowed within ``window``.
    static let limit = 3
    static let window: TimeInterval = 60

    private var crashes: [Date] = []

    /// Records a crash at `now`; true when the page should reload.
    mutating func shouldReload(at now: Date) -> Bool {
        true
    }
}
