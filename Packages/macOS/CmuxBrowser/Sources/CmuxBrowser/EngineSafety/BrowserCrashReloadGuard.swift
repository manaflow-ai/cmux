public import Foundation

/// Decides whether a pane may restore its page by itself after its content
/// process ends. A page that crashes as it loads would otherwise reload in a
/// loop; after `limit` automatic restores within `window` the pane waits for
/// an explicit Reload. Same rule as cmux Next's `PageCrashReloads`.
public struct BrowserCrashReloadGuard: Equatable, Sendable {
    public static let limit = 3
    /// Long because one load-to-crash cycle can take many seconds, and a slow
    /// crash loop must stop too.
    public static let window: TimeInterval = 600

    private var crashes: [Date] = []

    public init() {}

    /// Records a crash at `now`; true when the page may restore by itself.
    public mutating func allowsAutomaticRestore(at now: Date) -> Bool {
        crashes.removeAll { now.timeIntervalSince($0) >= Self.window }
        crashes.append(now)
        return crashes.count <= Self.limit
    }

    /// An explicit Reload by the person starts a fresh budget.
    public mutating func reset() {
        crashes.removeAll()
    }
}
