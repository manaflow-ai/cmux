public import CmuxNextDaemon
public import CmuxNextDesign

/// A `terminal` notification the session host posted for an OSC 7501 record
/// (cx-kxa2, cmux-tui-core `program_status_notify`): the daemon posts one
/// when a record changes into `blocked`, `error` or `done`, titled with the
/// record's title (else its app name), with its message as the body and a
/// level per state. The app finds the record again in the terminal's
/// `extra.program_status` (published before the notification) for the
/// banner's reason line and badge. Pure.
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
                return (record.title ?? record.app ?? "") == title && (record.msg ?? "") == body
            }
            .max { $0.updatedSeq < $1.updatedSeq }
            .flatMap { record in reason(record).map { ProgramStatusNotification(record: record, reason: $0) } }
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
