import CmuxNextDesignTokens
import Foundation

/// One history page open's failed reads: inside ``NoticeTiming/connectionQuiet`` from the first failure, a read no
/// owner answered shows as still loading (it is read again either way); past it, as failed. No Try Again (Leo,
/// 2026-11-22: "vacuous decisions like that should be just done").
@MainActor
public final class HistoryFailingSince {
    private var since: ContinuousClock.Instant?
    private let now: () -> ContinuousClock.Instant

    public init(now: @escaping () -> ContinuousClock.Instant = { ContinuousClock.now }) { self.now = now }

    /// `read` as the page shows it now.
    public func shown(_ read: HistoryRead, kinds: Set<HistoryEntry.Kind>) -> HistoryRead {
        guard read.unavailable else {
            since = nil
            return read
        }
        let start = since ?? now()
        since = start
        guard start.duration(to: now()) < NoticeTiming.connectionQuiet else { return read }
        var quiet = read
        quiet.unavailable = false
        quiet.pending.insert(kinds.first ?? .page)
        return quiet
    }
}
