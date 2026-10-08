public import Foundation

/// Pure rules for the footer button and which tip the popover opens on.
///
/// The button carries a small dot until the popover is opened for the first
/// time, then never again. Opening it on a new day moves on to the next
/// unseen tip, so each day starts on something new without any badge.
///
/// Pass a fixed time to exercise the reminder policy without an app or defaults:
/// ```swift
/// let schedule = SidebarTipsSchedule()
/// let next = schedule.automaticTip(SidebarTipsProgress(), tipIDs: ["split"], now: date)
/// ```
public struct SidebarTipsSchedule: Sendable {
    /// Creates the schedule for manual tips and daily automatic reminders.
    public init() {}

    /// Returns a local calendar day identifier for daily manual rotation.
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

    /// Returns an unseen tip only when automatic reminders are enabled and due.
    /// Manual presentations consume the same 24-hour allowance as automatic ones.
    /// - Parameters:
    ///   - progress: Persisted viewing history and the user's opt-out.
    ///   - tipIDs: Currently applicable tips in display order.
    ///   - now: The current time, supplied by the caller.
    /// - Returns: The next unseen tip, or nil while suppressed or exhausted.
    public func automaticTip(_ progress: SidebarTipsProgress, tipIDs: [String], now: Date) -> String? {
        guard !progress.automaticTipsDisabled,
              progress.lastOpenedDay != dayKey(for: now) else { return nil }
        if let lastOpenedAt = progress.lastOpenedAt, now.timeIntervalSince(lastOpenedAt) < 24 * 60 * 60 {
            return nil
        }
        return tipIDs.first { !progress.seenTipIDs.contains($0) }
    }

    /// Returns the selected tip's index, falling back when a tip was removed.
    public func currentIndex(_ progress: SidebarTipsProgress, tipIDs: [String]) -> Int {
        progress.currentTipID.flatMap { tipIDs.firstIndex(of: $0) } ?? 0
    }

    /// Records a presentation and rotates manual viewing on a new day.
    /// - Parameters:
    ///   - progress: Persisted viewing history.
    ///   - tipIDs: Currently applicable tip identifiers.
    ///   - now: Presentation time, supplied by the caller.
    /// - Returns: Updated selection, seen tips, and reminder timestamp.
    public func opened(
        _ progress: SidebarTipsProgress,
        tipIDs: [String],
        now: Date
    ) -> SidebarTipsProgress {
        guard !tipIDs.isEmpty else { return progress }
        let today = dayKey(for: now)
        var next = progress
        let currentIndex = progress.currentTipID.flatMap { tipIDs.firstIndex(of: $0) }
        if let currentIndex {
            let isNewDay = progress.lastOpenedDay != today
            if isNewDay, progress.seenTipIDs.contains(tipIDs[currentIndex]) {
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

