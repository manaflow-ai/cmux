import CmuxNextDevices
import Foundation

// The device hub's values as cmux-rd-core's `rd_hub_*` ops read and write them (snake_case JSON).

extension DeviceHubError {
    /// cmux-rd-core's `HubError`.
    nonisolated var rd: [String: Any] {
        switch self {
        case .notConfigured: ["error": "not_configured"]
        case .notSignedIn: ["error": "not_signed_in"]
        case let .server(status, code, message): ["error": "server", "status": status, "code": code.rawValue, "message": message]
        case let .http(status): ["error": "http", "status": status]
        case let .transport(detail): ["error": "transport", "detail": detail]
        case let .decoding(detail): ["error": "decoding", "detail": detail]
        case let .identity(detail): ["error": "identity", "detail": detail]
        }
    }
}

extension MacScreenHubRefusal {
    private nonisolated static let rdNames: [(String, Self)] = [
        ("permission_none", .permissionNone), ("scope_exceeds", .scopeExceeds), ("host_offline", .hostOffline),
        ("not_shared", .notShared), ("not_found", .notFound), ("not_signed_in", .notSignedIn),
    ]

    nonisolated init?(rd: [String: Any]?) {
        let name = rd?["refusal"] as? String
        if name == "other" { self = .other(reason: rd?["reason"] as? String); return }
        guard let named = Self.rdNames.first(where: { $0.0 == name }) else { return nil }
        self = named.1
    }

    nonisolated var rd: [String: Any] {
        if case let .other(reason) = self { return ["refusal": "other", "reason": reason as Any? ?? NSNull()] }
        return ["refusal": Self.rdNames.first { $0.1 == self }?.0 ?? "other"]
    }
}

extension MacScreenHubPhase {
    nonisolated init?(rd: [String: Any]?) {
        let id = rd?["session_id"] as? String ?? ""
        let scope = (rd?["scope"] as? String).flatMap(SessionScope.init(rawValue:)) ?? .full
        switch rd?["phase"] as? String {
        case "idle": self = .idle
        case "requesting": self = .requesting(scope)
        case "waiting_for_approval": self = .waitingForApproval(sessionID: id, scope: scope)
        case "approved": self = .approved(sessionID: id, scope: scope)
        case "streaming": self = .streaming(sessionID: id, scope: scope)
        case "stream_failed": self = .streamFailed(sessionID: id, scope: scope)
        case "declined": self = .declined(scope)
        case "refused":
            guard let refusal = MacScreenHubRefusal(rd: rd?["refusal"] as? [String: Any]) else { return nil }
            self = .refused(refusal, requested: (rd?["requested"] as? String).flatMap(SessionScope.init(rawValue:)) ?? .full)
        case "revoked": self = .revoked(reason: rd?["reason"] as? String)
        case "ended": self = .ended(reason: rd?["reason"] as? String)
        default: return nil
        }
    }

    nonisolated var rd: [String: Any] {
        let (name, scope): (String, SessionScope?) = switch self {
        case .idle: ("idle", nil)
        case let .requesting(scope): ("requesting", scope)
        case let .waitingForApproval(_, scope): ("waiting_for_approval", scope)
        case let .approved(_, scope): ("approved", scope)
        case let .streaming(_, scope): ("streaming", scope)
        case let .streamFailed(_, scope): ("stream_failed", scope)
        case let .declined(scope): ("declined", scope)
        case .refused: ("refused", nil)
        case .revoked: ("revoked", nil)
        case .ended: ("ended", nil)
        }
        var out: [String: Any] = ["phase": name]
        out["scope"] = scope?.rawValue
        out["session_id"] = sessionID
        switch self {
        case let .refused(refusal, requested): out["refusal"] = refusal.rd; out["requested"] = requested.rawValue
        case let .revoked(reason), let .ended(reason): out["reason"] = reason
        default: break
        }
        return out
    }
}

extension SessionTicket {
    /// A viewer's `Ticket`.
    nonisolated var rdViewer: [String: Any] {
        ["session_id": sessionId, "role": role.rawValue, "peer_id": peer.id, "scope": scope.rawValue]
    }

    /// The host's `HostTicket`.
    nonisolated var rdHost: [String: Any] {
        ["session_id": sessionId, "scope": scope.rawValue, "viewer_id": peer.id, "viewer_name": peer.name,
         "own_account": isOwnAccount, "served_by_daemon": isServedByDaemon]
    }
}

extension HubSession {
    nonisolated var rd: [String: Any] {
        var out: [String: Any] = ["id": id]
        out["state"] = state?.rawValue
        out["scope"] = scope?.rawValue
        return out
    }
}

/// A hub call's answer as cmux-rd-core's `Answer` (`{"ok": …}` or `{"err": HubError}`).
nonisolated func rdAnswer<T>(_ answer: Result<T, DeviceHubError>, _ ok: (T) -> [String: Any]) -> [String: Any] {
    switch answer {
    case let .success(value): ["ok": ok(value)]
    case let .failure(error): ["err": error.rd]
    }
}

/// One effect of a reducer reply, with the fields most effects carry.
struct RdEffect {
    let name: String
    let fields: [String: Any]
    var sessionID: String { fields["session_id"] as? String ?? "" }
    var reason: String { fields["reason"] as? String ?? "" }

    static func all(_ reply: [String: Any]?) -> [RdEffect] {
        (reply?["effects"] as? [[String: Any]] ?? []).compactMap { fields in
            (fields["effect"] as? String).map { RdEffect(name: $0, fields: fields) }
        }
    }
}
