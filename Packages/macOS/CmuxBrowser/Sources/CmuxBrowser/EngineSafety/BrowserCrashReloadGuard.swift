public import Foundation

/// Decides whether a pane may restore its page by itself after its content
/// process ends.
///
/// Only a pane that was hidden when its process ended may restore by itself
/// (when it is shown again). A pane that was visible always waits for an
/// explicit Reload, so a page that crashes its process cannot reload itself
/// in a loop in front of the person (Classic's WebKit rule,
/// `BrowserPanel+WebContentTermination.swift`). Hidden restores are capped
/// too: after `limit` within `window` the pane waits for Reload, because a
/// page that crashes as it loads would otherwise loop in the background.
/// Same cap as cmux Next's `PageCrashReloads`.
public struct BrowserCrashReloadGuard: Equatable, Sendable {
    public static let limit = 3
    /// Long because one load-to-crash cycle can take many seconds, and a slow
    /// crash loop must stop too.
    public static let window: TimeInterval = 600

    private var restores: [Date] = []

    public init() {}

    /// Records a process end at `now`; true when the page may restore by
    /// itself once its pane is shown.
    ///
    /// - Parameters:
    ///   - now: When the process ended.
    ///   - paneWasVisible: Whether the pane was on screen when it ended.
    public mutating func allowsAutomaticRestore(at now: Date, paneWasVisible: Bool) -> Bool {
        guard !paneWasVisible else { return false }
        restores.removeAll { now.timeIntervalSince($0) >= Self.window }
        guard restores.count < Self.limit else { return false }
        restores.append(now)
        return true
    }

    /// An explicit Reload by the person starts a fresh budget.
    public mutating func reset() {
        restores.removeAll()
    }
}
