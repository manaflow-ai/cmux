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
                    localized: "notification.claudeAccountAutoSwitch.resumed",
                    defaultValue: "%1$@ hit its usage limit (resets %2$@). Resumed the conversation on %3$@."
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
                    localized: "notification.claudeAccountAutoSwitch.resumedNoReset",
                    defaultValue: "%1$@ hit its usage limit. Resumed the conversation on %2$@."
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

    /// The notice when cmux stopped waiting to type `continue` on `to`, and why.
    ///
    /// - Parameters:
    ///   - reason: Why the wait ended.
    ///   - includingSwitch: The switch itself was not announced yet. The notice then also says
    ///     what ``notification(now:calendar:)`` would have, in one notification: a second one on
    ///     the same pane would replace the first.
    ///   - now: Decides whether a quoted reset time needs its date.
    ///   - calendar: The calendar and time zone the reset time is shown in.
    func notContinuedNotification(
        reason: ClaudeAccountAutoSwitchContinueGate.GiveUpReason,
        includingSwitch: Bool,
        now: Date,
        calendar: Calendar
    ) -> ClaudeAccountSwitchSocketOutcome.ResumeNotification {
        let format: String
        switch reason {
        case .timedOut:
            format = String(
                localized: "notification.claudeAccountAutoSwitch.notContinued.timedOut",
                defaultValue: "cmux didn't type continue on %@: Claude didn't reach an empty prompt within a minute."
            )
        case .sessionEnded:
            format = String(
                localized: "notification.claudeAccountAutoSwitch.notContinued.sessionEnded",
                defaultValue: "cmux didn't type continue on %@: the resumed Claude session ended."
            )
        case .sessionBusy, .otherSession, .userInput:
            format = String(
                localized: "notification.claudeAccountAutoSwitch.notContinued.inUse",
                defaultValue: "cmux didn't type continue on %@: the terminal was in use."
            )
        case .disabled:
            format = String(
                localized: "notification.claudeAccountAutoSwitch.notContinued.disabled",
                defaultValue: "cmux didn't type continue on %@: automatic account switching was turned off."
            )
        case .paneGone:
            format = String(
                localized: "notification.claudeAccountAutoSwitch.notContinued.paneGone",
                defaultValue: "cmux didn't type continue on %@: the terminal was closed."
            )
        }
        let reasonText = String(format: format, to)
        return ClaudeAccountSwitchSocketOutcome.ResumeNotification(
            title: String(localized: "notification.claudeAccountSwitch.title", defaultValue: "Claude account switched"),
            subtitle: statusText,
            body: includingSwitch ? body(now: now, calendar: calendar) + "\n" + reasonText : reasonText
        )
    }

    /// The notification when `from` hit its usage limit and another account was free, but the
    /// pane was left alone.
    static func holdBackNotification(
        from: String,
        reason: ClaudeAccountAutoSwitchAction.HoldBack
    ) -> ClaudeAccountSwitchSocketOutcome.ResumeNotification {
        let format: String
        switch reason {
        case .userInput:
            format = String(
                localized: "notification.claudeAccountAutoSwitch.notSwitched.userInput",
                defaultValue: "%@ hit its usage limit, but the terminal was used afterwards, so cmux didn't switch accounts. Switch accounts manually to continue."
            )
        case .draftPending:
            format = String(
                localized: "notification.claudeAccountAutoSwitch.notSwitched.draftPending",
                defaultValue: "%@ hit its usage limit while a message was typed in Claude's input box. Switching accounts restarts the terminal and would discard it, so cmux didn't switch. Switch accounts manually to continue."
            )
        case .backgroundWork:
            format = String(
                localized: "notification.claudeAccountAutoSwitch.notSwitched.backgroundWork",
                defaultValue: "%@ hit its usage limit while background work was still running. Switching accounts restarts the terminal and would stop that work, so cmux didn't switch. Switch accounts manually when it's done."
            )
        case .attemptLimit:
            format = String(
                localized: "notification.claudeAccountAutoSwitch.notSwitched.attemptLimit",
                defaultValue: "%@ hit its usage limit. This terminal already went through every other account without finishing a turn, so cmux stopped switching it automatically."
            )
        case .notRecorded:
            format = String(
                localized: "notification.claudeAccountAutoSwitch.notSwitched.notRecorded",
                defaultValue: "%@ hit its usage limit, but cmux couldn't record that, so it didn't switch accounts automatically. Switch accounts manually to continue."
            )
        }
        return ClaudeAccountSwitchSocketOutcome.ResumeNotification(
            title: String(
                localized: "notification.claudeAccountAutoSwitch.notSwitched.title",
                defaultValue: "Claude account not switched"
            ),
            subtitle: "",
            body: String(format: format, from)
        )
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
