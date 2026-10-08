public import Foundation

/// Pure rules for the footer button and which tip the popover opens on.
///
/// The button carries a small dot until the popover is opened for the first
/// time, then never again. Manual openings advance through unseen tips first.
/// Automatic tips offer something new daily, then a weekly refresher once the
/// currently available catalog has been seen.
///
/// Pass a fixed time to exercise the reminder policy without an app or defaults:
/// ```swift
/// let schedule = SidebarTipsSchedule()
/// let next = schedule.automaticTip(SidebarTipsProgress(), tipIDs: ["split"], now: date)
/// ```
public struct SidebarTipsSchedule: Sendable {
    /// Creates the schedule for manual tips, daily discovery, and weekly refreshers.
    public init() {}

    /// Returns a local calendar day identifier for legacy reminder history.
    public func dayKey(for date: Date, calendar: Calendar = .current) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04ld-%02ld-%02ld",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
    }

    /// Whether the button still needs its one-time discovery indicator.
    public func showsUnopenedIndicator(_ progress: SidebarTipsProgress) -> Bool {
        !progress.automaticTipsDisabled && progress.lastOpenedDay == nil
    }

    /// Returns a new tip daily, or a rotating refresher after a week without tips.
    /// Manual presentations consume the same 24-hour allowance as automatic ones.
    /// - Parameters:
    ///   - progress: Persisted viewing history and the user's opt-out.
    ///   - tipIDs: Currently applicable tips in display order.
    ///   - now: The current time, supplied by the caller.
    /// - Returns: The next eligible tip, or nil while suppressed or empty.
    public func automaticTip(_ progress: SidebarTipsProgress, tipIDs: [String], now: Date) -> String? {
        guard !progress.automaticTipsDisabled,
              progress.lastOpenedDay != dayKey(for: now) else { return nil }
        if let lastOpenedAt = progress.lastOpenedAt, now.timeIntervalSince(lastOpenedAt) < 24 * 60 * 60 {
            return nil
        }
        if let unseen = tipIDs.first(where: { !progress.seenTipIDs.contains($0) }) {
            return unseen
        }
        guard !tipIDs.isEmpty, let lastOpenedAt = progress.lastOpenedAt,
              now.timeIntervalSince(lastOpenedAt) >= 7 * 24 * 60 * 60 else { return nil }
        let nextIndex = progress.currentTipID.flatMap { tipIDs.firstIndex(of: $0) }
            .map { ($0 + 1) % tipIDs.count } ?? 0
        return tipIDs[nextIndex]
    }

    /// Returns the selected tip's index, falling back when a tip was removed.
    public func currentIndex(_ progress: SidebarTipsProgress, tipIDs: [String]) -> Int {
        progress.currentTipID.flatMap { tipIDs.firstIndex(of: $0) } ?? 0
    }

    /// Records a presentation, advancing manual viewing to the next unseen tip.
    /// - Parameters:
    ///   - progress: Persisted viewing history.
    ///   - tipIDs: Currently applicable tip identifiers.
    ///   - now: Presentation time, supplied by the caller.
    ///   - preferredTipID: An automatic selection to show exactly, including refreshers.
    /// - Returns: Updated selection, seen tips, and reminder timestamp.
    public func opened(
        _ progress: SidebarTipsProgress,
        tipIDs: [String],
        now: Date,
        preferredTipID: String? = nil
    ) -> SidebarTipsProgress {
        guard !tipIDs.isEmpty else { return progress }
        let today = dayKey(for: now)
        var next = progress
        let currentIndex = progress.currentTipID.flatMap { tipIDs.firstIndex(of: $0) }
        if let preferredTipID, tipIDs.contains(preferredTipID) {
            next.currentTipID = preferredTipID
        } else if let currentIndex {
            if progress.seenTipIDs.contains(tipIDs[currentIndex]) {
                let count = tipIDs.count
                let following = (1...count).map { tipIDs[(currentIndex + $0) % count] }
                next.currentTipID = following.first { !progress.seenTipIDs.contains($0) }
                    ?? tipIDs[(currentIndex + 1) % count]
            }
        } else {
            next.currentTipID = tipIDs.first { !progress.seenTipIDs.contains($0) } ?? tipIDs[0]
        }
        next.lastOpenedDay = today
        next.lastOpenedAt = now
        if let currentTipID = next.currentTipID {
            next.seenTipIDs.insert(currentTipID)
        }
        return next
    }

    /// Progress after the user pages to `tipID` inside the popover.
    public func selected(_ progress: SidebarTipsProgress, tipID: String) -> SidebarTipsProgress {
        var next = progress
        next.currentTipID = tipID
        next.seenTipIDs.insert(tipID)
        return next
    }
}
