public import CmuxNextDaemon
public import CmuxNextDesign

/// A `terminal` notification the session host posted for an OSC 7501 record
/// (cmux-tui-core `program_status::raise_alert`): when a record starts
/// waiting on the user or fails (and, once the daemon raises it, finishes),
/// the reader posts "<title, else app, else A program> <verb>" with the
/// record's message as the body, `warning` for a wait, `error` for a failure,
/// `info` for done. The app finds the record again in the terminal's
/// `extra.program_status` for the banner's badge and the done-visibility
/// rule (cx-kxa2). The rules are cmux-window-rules `notification_notices`
/// (`program_*`).
public struct ProgramStatusNotification: Hashable, Sendable {
    /// Why the program notified: the banner's reason line and badge.
    public enum Reason: String, Hashable, Sendable, CaseIterable {
        case permission, question, auth
        /// Blocked without a kind.
        case input
        case failed, done

        /// The indicator state the badge draws.
        public var indicator: StatusIndicatorState {
            switch self {
            case .permission, .question, .auth, .input: .waiting
            case .failed: .error
            case .done: .success
            }
        }

        /// The record's blocked kind, nil for every other reason.
        public var kind: ProgramStatusRecord.Kind? {
            switch self {
            case .permission: .permission
            case .question: .question
            case .auth: .auth
            case .input, .failed, .done: nil
            }
        }
    }

    public var record: ProgramStatusRecord
    public var reason: Reason

    /// The record a notification with `title`, `body` and `level` was posted
    /// for, nil for any other terminal notification (OSC 9, 777, 99). Among
    /// several matches the newest report wins.
    public static func match(title: String, body: String, level: NotificationLevel,
                             records: [ProgramStatusRecord]) -> ProgramStatusNotification? {
        StatusNotices.programMatch(title: title, body: body, level: level, records: records)
            .map { ProgramStatusNotification(record: records[$0.record], reason: $0.reason) }
    }

    /// Whether a `terminal` notification reads like an OSC 7501 alert ("<name>
    /// <verb>" at the verb's level) whose record may not have arrived yet:
    /// the session events stream can deliver the record after the
    /// notification, so the app waits briefly for it before the banner.
    public static func looksLikeAlert(title: String, level: NotificationLevel) -> Bool {
        StatusNotices.looksLikeAlert(title: title, level: level)
    }

    /// Whether it shows at all: `done` only for a terminal the user cannot
    /// see (Lawrence, cx-kxa2); the rest follow the normal notification rules.
    public func notifies(visibility: TerminalVisibility) -> Bool {
        StatusNotices.programNotifies(reason, visibility: visibility)
    }
}
