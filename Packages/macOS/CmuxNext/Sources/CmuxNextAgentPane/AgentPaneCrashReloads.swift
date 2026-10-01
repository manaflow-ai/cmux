import Foundation

/// Decides whether a pane reloads its page after the web content process
/// crashes. A page that crashes as it loads would otherwise reload forever.
nonisolated struct AgentPaneCrashReloads: Equatable, Sendable {
    /// Reloads allowed within ``window``. The window is long because one
    /// load-to-crash cycle can take 20 seconds or more (the handshake waits
    /// for acpmux), and a slow crash loop must stop too.
    static let limit = 3
    static let window: TimeInterval = 600

    private var crashes: [Date] = []

    /// Records a crash at `now`; true when the page should reload.
    mutating func shouldReload(at now: Date) -> Bool {
        crashes.removeAll { now.timeIntervalSince($0) >= Self.window }
        crashes.append(now)
        return crashes.count <= Self.limit
    }
}
