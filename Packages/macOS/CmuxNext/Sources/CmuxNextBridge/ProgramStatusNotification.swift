public import CmuxNextDaemon
public import CmuxNextDesign

/// A `terminal` notification the session host posted for an OSC 7501 record
/// (cmux-tui-core `program_status::raise_alert`): when a record starts
/// waiting on the user or fails (and, once the daemon raises it, finishes),
/// the reader posts "<title, else app, else A program> <verb>" with the
/// record's message as the body, `warning` for a wait, `error` for a failure,
/// `info` for done. The app finds the record again in the terminal's
/// `extra.program_status` for the banner's badge and the done-visibility
/// rule (cx-kxa2). Pure.
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
        records
            .filter { record in
                guard let reason = reason(record), level == Self.level(reason) else { return false }
                let name = record.title ?? record.app ?? "A program"
                return clipped("\(name) \(verb(reason))", to: titleLimit) == title
                    && clipped(record.msg ?? "", to: bodyLimit) == body
            }
            .max { $0.updatedSeq < $1.updatedSeq }
            .flatMap { record in reason(record).map { ProgramStatusNotification(record: record, reason: $0) } }
    }

    /// Whether a `terminal` notification reads like an OSC 7501 alert ("<name>
    /// <verb>" at the verb's level) whose record may not have arrived yet:
    /// the session events stream can deliver the record after the
    /// notification, so the app waits briefly for it before the banner.
    public static func looksLikeAlert(title: String, level: NotificationLevel) -> Bool {
        Reason.allCases.contains { reason in
            let suffix = " " + verb(reason)
            return Self.level(reason) == level && title.hasSuffix(suffix) && title.count > suffix.count
        }
    }

    /// The daemon's notification text limits (terminal_metadata.rs).
    static let titleLimit = 256
    static let bodyLimit = 1024

    static func clipped(_ text: String, to limit: Int) -> String {
        text.count > limit ? String(text.prefix(limit)) : text
    }

    /// The daemon's wording (program_status.rs `raise_alert`).
    static func verb(_ reason: Reason) -> String {
        switch reason {
        case .permission: "needs approval"
        case .question: "asks a question"
        case .auth: "needs sign-in"
        case .input: "needs input"
        case .failed: "failed"
        case .done: "is done"
        }
    }

    /// Whether it shows at all: `done` only for a terminal the user cannot
    /// see (Lawrence, cx-kxa2); the rest follow the normal notification rules.
    public func notifies(visibility: TerminalVisibility) -> Bool {
        reason != .done || !visibility.isVisible
    }

    static func reason(_ record: ProgramStatusRecord) -> Reason? {
        switch record.state {
        case .blocked:
            switch record.kind {
            case .permission?: .permission
            case .question?: .question
            case .auth?: .auth
            case nil: .input
            }
        case .error: .failed
        case .done: .done
        case .working, .idle: nil
        }
    }

    static func level(_ reason: Reason) -> NotificationLevel {
        switch reason {
        case .permission, .question, .auth, .input: .warning
        case .failed: .error
        case .done: .info
        }
    }
}
