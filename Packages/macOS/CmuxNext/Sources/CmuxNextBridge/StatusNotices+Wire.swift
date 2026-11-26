import CmuxNextDaemon
import CmuxNextWindowRules

/// The status notices' rules, asked of cmux-window-rules `notification_notices` over the app FFI's
/// JSON channel: the `cmux status run`s that finished (`status_runs_finished`), whether one
/// notifies (`status_run_notifies`), and the OSC 7501 record a `terminal` notification was posted
/// for (`program_*`). With no answer (logged by ``WindowRules``) no run finishes or notifies, no
/// record matches, and a program alert shows as any notification does.
nonisolated enum StatusNotices {
    /// A run busy at a look: its workspace and entry key.
    struct RunKey: Codable, Hashable, Sendable {
        var workspace: String
        var key: String
    }

    /// The runs of `statuses` that finished since `running` was busy, in the statuses' order,
    /// and the runs busy now; nil when the FFI did not answer.
    static func finished(running: [RunKey], statuses: [WorkspaceStatus]) -> (finished: [FinishedStatusRun], running: [RunKey])? {
        let request = RunsRequest(running: running, statuses: statuses.map { status in
            RunsRequest.Status(workspace: status.workspaceID.rawValue, entries: status.entries.map { .init(key: $0.key, state: $0.state) })
        })
        guard let reply = WindowRules().call("notification_notices_status_runs_finished", request, as: RunsReply.self) else { return nil }
        let finished = reply.finished.compactMap { found -> FinishedStatusRun? in
            guard statuses.indices.contains(found.status), statuses[found.status].entries.indices.contains(found.entry) else { return nil }
            let status = statuses[found.status]
            let entry = status.entries[found.entry]
            return FinishedStatusRun(workspace: status.workspaceID, key: entry.key, label: entry.text, terminal: entry.targetTerminal,
                                     succeeded: entry.state == "success", exitCode: entry.exitCode, durationMs: entry.durationMs)
        }
        return (finished, reply.running)
    }

    /// Whether a run of `durationMs` notifies under `minimumSeconds` and `whenVisible`, its terminal at `visibility`.
    static func runNotifies(durationMs: UInt64?, minimumSeconds: Double, whenVisible: Bool, visibility: TerminalVisibility) -> Bool {
        let request = RunNotifiesRequest(durationMs: durationMs, minimumSeconds: minimumSeconds, whenVisible: whenVisible,
                                         visibility: Visibility(visibility))
        return WindowRules().call("notification_notices_status_run_notifies", request, as: RunNotifiesReply.self)?.notifies ?? false
    }

    /// The index into `records` of the record a notification with `title`, `body` and `level` was posted for, and why.
    static func programMatch(title: String, body: String, level: NotificationLevel, records: [ProgramStatusRecord])
        -> (record: Int, reason: ProgramStatusNotification.Reason)? {
        let request = ProgramMatchRequest(title: title, body: body, level: level.rawValue, records: records.map(ProgramRecord.init))
        guard let found = WindowRules().call("notification_notices_program_match", request, as: ProgramMatchReply.self)?.match,
              records.indices.contains(found.record),
              let reason = ProgramStatusNotification.Reason(rawValue: found.reason) else { return nil }
        return (found.record, reason)
    }

    /// Whether a notification titled `title` at `level` reads like an OSC 7501 alert.
    static func looksLikeAlert(title: String, level: NotificationLevel) -> Bool {
        let request = AlertRequest(title: title, level: level.rawValue)
        return WindowRules().call("notification_notices_program_looks_like_alert", request, as: AlertReply.self)?.alert ?? false
    }

    /// Whether a program alert for `reason` shows at all, its terminal at `visibility`.
    static func programNotifies(_ reason: ProgramStatusNotification.Reason, visibility: TerminalVisibility) -> Bool {
        let request = ProgramNotifiesRequest(reason: reason.rawValue, visibility: Visibility(visibility))
        return WindowRules().call("notification_notices_program_notifies", request, as: ProgramNotifiesReply.self)?.notifies ?? true
    }
}

private nonisolated struct RunsRequest: Encodable {
    struct Entry: Encodable {
        var key: String
        var state: String?
    }

    struct Status: Encodable {
        var workspace: String
        var entries: [Entry]
    }

    var running: [StatusNotices.RunKey]
    var statuses: [Status]
}

private nonisolated struct RunsReply: Decodable {
    struct Finished: Decodable {
        var status: Int
        var entry: Int
    }

    var finished: [Finished]
    var running: [StatusNotices.RunKey]
}

private nonisolated struct Visibility: Encodable {
    var tabSelected: Bool
    var paneOnScreen: Bool
    var windowShown: Bool
    var appActive: Bool

    init(_ visibility: TerminalVisibility) {
        tabSelected = visibility.tabSelected
        paneOnScreen = visibility.paneOnScreen
        windowShown = visibility.windowShown
        appActive = visibility.appActive
    }
}

private nonisolated struct RunNotifiesRequest: Encodable {
    var durationMs: UInt64?
    var minimumSeconds: Double
    var whenVisible: Bool
    var visibility: Visibility
}

private nonisolated struct RunNotifiesReply: Decodable {
    var notifies: Bool
}

private nonisolated struct ProgramRecord: Encodable {
    var state: String
    var kind: String?
    var title: String?
    var app: String?
    var msg: String?
    var updatedSeq: UInt64

    init(_ record: ProgramStatusRecord) {
        state = record.state.rawValue
        kind = record.kind?.rawValue
        title = record.title
        app = record.app
        msg = record.msg
        updatedSeq = record.updatedSeq
    }
}

private nonisolated struct ProgramMatchRequest: Encodable {
    var title: String
    var body: String
    var level: String
    var records: [ProgramRecord]
}

private nonisolated struct ProgramMatchReply: Decodable {
    struct Match: Decodable {
        var record: Int
        var reason: String
    }

    var match: Match?
}

private nonisolated struct AlertRequest: Encodable {
    var title: String
    var level: String
}

private nonisolated struct AlertReply: Decodable {
    var alert: Bool
}

private nonisolated struct ProgramNotifiesRequest: Encodable {
    var reason: String
    var visibility: Visibility
}

private nonisolated struct ProgramNotifiesReply: Decodable {
    var notifies: Bool
}
