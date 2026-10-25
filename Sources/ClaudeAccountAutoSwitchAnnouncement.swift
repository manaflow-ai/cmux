import Foundation

/// The sidebar status and notification for an automatic Claude account switch.
struct ClaudeAccountAutoSwitchAnnouncement: Equatable, Sendable {
    /// The account that hit its usage limit.
    let from: String
    /// The account the pane moved to.
    let to: String
    /// When `from` resets, as its limit message gave it; `nil` when it gave none.
    let reset: Date?
    /// Whether cmux types `continue`. False when `to` has not trusted the folder yet, so the
    /// user confirms trust first.
    let continues: Bool

    /// The sidebar status row: `Claude account: <from> → <to> (auto)`.
    var statusText: String {
        String(
            format: String(
                localized: "sidebar.claudeAccountAutoSwitch.status",
                defaultValue: "Claude account: %1$@ → %2$@ (auto)"
            ),
            from,
            to
        )
    }

    /// The notification for a switch whose resume was typed. The title is the one every
    /// Claude account switch notification uses.
    ///
    /// - Parameters:
    ///   - now: Decides whether the reset time needs its date.
    ///   - calendar: The calendar and time zone the reset time is shown in.
    func notification(now: Date, calendar: Calendar) -> ClaudeAccountSwitchSocketOutcome.ResumeNotification {
        ClaudeAccountSwitchSocketOutcome.ResumeNotification(
            title: String(
                localized: "notification.claudeAccountSwitch.title",
                defaultValue: "Claude account switched"
            ),
            subtitle: statusText,
            body: body(now: now, calendar: calendar)
        )
    }

    private func body(now: Date, calendar: Calendar) -> String {
        switch (reset.map { Self.resetText($0, now: now, calendar: calendar) }, continues) {
        case (let reset?, true):
            return String(
                format: String(
                    localized: "notification.claudeAccountAutoSwitch.continuing",
                    defaultValue: "%1$@ hit its usage limit (resets %2$@). Continuing on %3$@."
                ),
                from,
                reset,
                to
            )
        case (let reset?, false):
            return String(
                format: String(
                    localized: "notification.claudeAccountAutoSwitch.confirmTrust",
                    defaultValue: "%1$@ hit its usage limit (resets %2$@). Confirm folder trust in %3$@, then continue."
                ),
                from,
                reset,
                to
            )
        case (nil, true):
            return String(
                format: String(
                    localized: "notification.claudeAccountAutoSwitch.continuingNoReset",
                    defaultValue: "%1$@ hit its usage limit. Continuing on %2$@."
                ),
                from,
                to
            )
        case (nil, false):
            return String(
                format: String(
                    localized: "notification.claudeAccountAutoSwitch.confirmTrustNoReset",
                    defaultValue: "%1$@ hit its usage limit. Confirm folder trust in %2$@, then continue."
                ),
                from,
                to
            )
        }
    }

    /// `reset` as the notification shows it: the time alone on the same day as `now`, the date
    /// and time otherwise.
    static func resetText(_ reset: Date, now: Date, calendar: Calendar) -> String {
        let sameDay = calendar.isDate(reset, inSameDayAs: now)
        let style = Date.FormatStyle(
            date: sameDay ? .omitted : .abbreviated,
            time: .shortened,
            calendar: calendar,
            timeZone: calendar.timeZone
        )
        return reset.formatted(style)
    }
}
