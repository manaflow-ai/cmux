public import CmuxNextDaemon
public import CmuxNextDesign
import CmuxNextWindowRules

/// A `terminal` notification the session host posted for an OSC 7501 record
/// (cmux-tui-core `program_status::raise_alert`): when a record starts
/// waiting on the user or fails (and, once the daemon raises it, finishes),
/// the reader posts "<title, else app, else A program> <verb>" with the
/// record's message as the body, `warning` for a wait, `error` for a failure,
/// `info` for done. The app finds the record again in the terminal's
/// `extra.program_status` for the banner's badge and the done-visibility
/// rule (cx-kxa2). The rules are Rust's (cmux-window-rules `status_alerts`,
/// ops `window_notifications_program_alert`, `_looks_like_alert`,
/// `_alert_notifies`); this keeps the badge each reason draws.
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
        guard !records.isEmpty else { return nil }
        struct Request: Encodable { var title: String, body: String, level: String, records: [RecordWire] }
        struct Found: Decodable { var index: Int, reason: String }
        struct Reply: Decodable { var alert: Found? }
        let request = Request(title: title, body: body, level: level.rawValue, records: records.map(RecordWire.init))
        // An FFI without the op answers nothing: no record, so the notification shows as any terminal one.
        guard let found = WindowRules().call("window_notifications_program_alert", request, as: Reply.self)?.alert,
              records.indices.contains(found.index), let reason = Reason(rawValue: found.reason) else { return nil }
        return ProgramStatusNotification(record: records[found.index], reason: reason)
    }

    /// Whether a `terminal` notification reads like an OSC 7501 alert ("<name>
    /// <verb>" at the verb's level) whose record may not have arrived yet:
    /// the session events stream can deliver the record after the
    /// notification, so the app waits briefly for it before the banner.
    public static func looksLikeAlert(title: String, level: NotificationLevel) -> Bool {
        struct Request: Encodable { var title: String, level: String }
        struct Reply: Decodable { var looksLikeAlert: Bool }
        // An FFI without the op answers nothing: no wait, the banner shows at once.
        return WindowRules().call("window_notifications_looks_like_alert", Request(title: title, level: level.rawValue),
                                  as: Reply.self)?.looksLikeAlert ?? false
    }

    /// Whether it shows at all: `done` only for a terminal the user cannot
    /// see (Lawrence, cx-kxa2); the rest follow the normal notification rules.
    public func notifies(visibility: TerminalVisibility) -> Bool {
        struct Request: Encodable { var reason: String, visibility: TerminalVisibility.Wire }
        struct Reply: Decodable { var notifies: Bool }
        let request = Request(reason: reason.rawValue, visibility: TerminalVisibility.Wire(visibility))
        // An FFI without the op answers nothing: it follows the normal notification rules.
        return WindowRules().call("window_notifications_alert_notifies", request, as: Reply.self)?.notifies ?? true
    }

    /// An OSC 7501 record as cmux-window-rules `status_alerts::Record` reads it.
    struct RecordWire: Encodable {
        var state: String, kind: String?, app: String?, title: String?, msg: String?, updatedSeq: UInt64

        init(_ record: ProgramStatusRecord) {
            state = record.state.rawValue
            kind = record.kind?.rawValue
            app = record.app
            title = record.title
            msg = record.msg
            updatedSeq = record.updatedSeq
        }
    }
}
