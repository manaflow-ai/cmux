// SPDX-License-Identifier: GPL-3.0-or-later
public import Foundation

/// A person's answer to one approval question (docs/computer-use-approvals.md).
public nonisolated enum ComputerUseApprovalDecision: String, Sendable, CaseIterable, Codable {
    /// This call only.
    case once
    /// The app joins this agent session's manifest.
    case session
    /// The app joins this cmux client's saved list (and this session).
    case always
    /// This call is refused (`approval_denied`).
    case deny

    public var allows: Bool { self != .deny }
}

/// Which collector answered.
public nonisolated enum ComputerUseApprovalVia: String, Sendable, Codable {
    /// The cmux app's card on this Mac (a person's click or key).
    case mac
    /// The owner's iPhone (Face ID signed, through cmux-mobile-host).
    case phone
}

/// The JSON lines this app writes on the worker's host consent link for approvals, and the
/// questions it reads there.
nonisolated enum ComputerUseApprovalWire {
    /// `{"type":"app_approval","id":N,"ok":true,"decision":…,"digest":…,"via":…}`.
    static func answer(id: Int, decision: ComputerUseApprovalDecision, digest: String, via: ComputerUseApprovalVia) -> Data {
        line(["type": "app_approval", "id": id, "ok": true, "decision": decision.rawValue, "digest": digest, "via": via.rawValue])
    }

    /// `{"type":"app_approval","id":N,"ok":false}`: no collector answered, the question is gone.
    static func unanswered(id: Int) -> Data {
        line(["type": "app_approval", "id": id, "ok": false])
    }

    /// `{"type":"approved_apps","apps":[…]}`: the client's saved list, replacing the previous one.
    static func approvedApps(_ apps: [ComputerUseApprovalApp]) -> Data {
        line(["type": "approved_apps", "apps": apps.map(\.wire)])
    }

    /// `{"type":"revoke","scope":"all"}` or `{"type":"revoke","scope":"app","app":{…}}`.
    static func revoke(_ app: ComputerUseApprovalApp?) -> Data {
        guard let app else { return line(["type": "revoke", "scope": "all"]) }
        return line(["type": "revoke", "scope": "app", "app": app.wire])
    }

    /// One line from the worker that concerns approvals.
    enum Incoming: Equatable, Sendable {
        /// A well-formed question.
        case question(id: Int, request: ComputerUseApprovalRequest)
        /// A question whose request failed its checks: answered `ok:false` at once.
        case malformed(id: Int)
        case cancel(id: Int)
    }

    /// Reads an approval line; nil for any other type (or one without an id).
    static func parse(_ object: [String: Any]) -> Incoming? {
        guard let type = object["type"] as? String, type == "app_approval" || type == "app_approval_cancel",
              let id = object["id"] as? Int else { return nil }
        if type == "app_approval_cancel" { return .cancel(id: id) }
        guard let request = ComputerUseApprovalRequest(object["request"]) else { return .malformed(id: id) }
        return .question(id: id, request: request)
    }

    static func line(_ fields: [String: Any]) -> Data {
        var data = (try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        data.append(0x0A)
        return data
    }
}
