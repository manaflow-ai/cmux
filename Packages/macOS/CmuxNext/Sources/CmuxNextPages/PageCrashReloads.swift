public import Foundation

/// Decides whether a page reloads after its web content process crashes (every page on the page
/// host, and the old agent pane host until it is deleted). A page that crashes as it loads would
/// otherwise reload forever.
public nonisolated struct PageCrashReloads: Equatable, Sendable {
    /// Reloads allowed within ``window``. The window is long because one
    /// load-to-crash cycle can take 20 seconds or more (the handshake waits
    /// for acpmux), and a slow crash loop must stop too.
    public static let limit = 3
    public static let window: TimeInterval = 600

    private var crashes: [Date] = []

    public init() {}

    /// Records a crash at `now`; true when the page should reload.
    public mutating func shouldReload(at now: Date) -> Bool {
        crashes.removeAll { now.timeIntervalSince($0) >= Self.window }
        crashes.append(now)
        return crashes.count <= Self.limit
    }
}
