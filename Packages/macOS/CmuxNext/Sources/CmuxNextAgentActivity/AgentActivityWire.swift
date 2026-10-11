import Foundation

/// Maps the CUA host's wire JSON (plans/cmux-next/computer-use.md section
/// 6a: `SessionRecord`, `Event`, timeline `frames`) to the pane's types.
/// Pure; unknown or malformed rows are skipped.
nonisolated enum AgentActivityWire {
    static func session(_ json: [String: Any], machine: String, machineName: String) -> AgentActivitySession? {
        guard let id = json["id"] as? String else { return nil }
        let agent = json["agent"] as? [String: Any] ?? [:]
        let kind = agent["kind"] as? String ?? "unknown"
        let status = json["status"] as? [String: Any] ?? [:]
        let counters = json["counters"] as? [String: Any] ?? [:]
        let targets = json["targets"] as? [[String: Any]] ?? []
        var apps: [String] = []
        for target in targets {
            if let app = target["app_name"] as? String, !apps.contains(app) { apps.append(app) }
        }
        return AgentActivitySession(
            id: id, machine: machine, machineName: machineName, label: json["label"] as? String ?? id,
            agentKind: kind, agentName: agentName(kind), attribution: AgentActivityAttribution(rawValue: agent["attribution"] as? String ?? "") ?? .none,
            workspaceTitle: agent["workspace_id"] as? String, terminalTitle: agent["terminal_id"] as? String,
            colorHex: json["color"] as? String ?? "#888888", targetApps: apps, status: self.status(status),
            startedAt: date(json["started_at_ms"]), lastActionAt: date(json["last_action_at_ms"]),
            endedAt: (json["ended_at_ms"] as? NSNumber).map { date($0) },
            acts: int(counters["acts"]), observes: int(counters["observes"]), errors: int(counters["errors"]),
            foregroundOnly: json["delivery"] as? String == "foreground_only")
    }

    static func status(_ json: [String: Any]) -> AgentActivityStatus {
        switch json["state"] as? String {
        case "idle": .idle
        case "paused": .paused
        case "ended": .ended(AgentActivityEndReason(rawValue: json["reason"] as? String ?? "") ?? .agentEnd)
        default: .active
        }
    }

    /// Events of a timeline page; `frames` gives each blob's size and state.
    static func events(_ page: [String: Any]) -> [AgentActivityEvent] {
        let frames = page["frames"] as? [String: [String: Any]] ?? [:]
        let rows = page["events"] as? [[String: Any]] ?? []
        return rows.compactMap { event($0, frames: frames) }
    }

    static func event(_ json: [String: Any], frames: [String: [String: Any]]) -> AgentActivityEvent? {
        guard let seq = (json["seq"] as? NSNumber)?.uint64Value,
              let kind = AgentActivityEventKind(rawValue: json["kind"] as? String ?? "") else { return nil }
        let result = json["result"] as? [String: Any]
        let target = json["target"] as? [String: Any]
        func frame(_ key: String) -> AgentActivityFrameRef? {
            guard let blob = json[key] as? String else { return nil }
            let info = frames[blob] ?? [:]
            return AgentActivityFrameRef(blob: blob, width: int(info["width"]), height: int(info["height"]),
                                         expired: info["expired"] as? Bool ?? false)
        }
        let after = frame("after_frame")
        let before = frame("before_frame")
        var click: CGPoint?
        if let point = json["click_point"] as? [String: Any], let x = (point["x"] as? NSNumber)?.doubleValue,
           let y = (point["y"] as? NSNumber)?.doubleValue,
           let blob = (json["after_frame"] ?? json["before_frame"]) as? String, let info = frames[blob] {
            let width = Double(int(info["source_width"])), height = Double(int(info["source_height"]))
            if width > 0, height > 0 { click = CGPoint(x: x / width, y: y / height) }
        }
        let errorCode = result?["error_code"] as? String ?? json["reject"] as? String
        return AgentActivityEvent(
            seq: seq, time: date(json["ts_ms"]), kind: kind, tool: json["tool"] as? String,
            target: [target?["app_name"] as? String, (target?["window_id"] as? NSNumber).map { "window \($0)" }]
                .compactMap { $0 }.joined(separator: " · ").nilIfEmpty,
            ok: (result?["ok"] as? Bool ?? true) && json["reject"] == nil, errorCode: errorCode,
            durationMs: (json["duration_ms"] as? NSNumber)?.intValue,
            redactedTextLength: redactedLength(json["args_redacted"]), beforeFrame: before, afterFrame: after, clickPoint: click)
    }

    /// Length of the first `{"redacted": "text", "length": n}` in the args.
    static func redactedLength(_ value: Any?) -> Int? {
        if let dict = value as? [String: Any] {
            if dict["redacted"] as? String == "text", let length = dict["length"] as? NSNumber { return length.intValue }
            for child in dict.values { if let found = redactedLength(child) { return found } }
        } else if let array = value as? [Any] {
            for child in array { if let found = redactedLength(child) { return found } }
        }
        return nil
    }

    static func agentName(_ kind: String) -> String {
        switch kind {
        case "claude": "Claude Code"
        case "codex": "Codex"
        case "opencode": "OpenCode"
        case "mux": "mux"
        default: kind
        }
    }

    /// Request line, with the socket credential envelope when configured.
    static func requestLine(method: String, args: [String: Any], authToken: String?, hostAuthToken: String?) -> Data {
        let request: [String: Any] = ["method": method, "args": args]
        let body: [String: Any]
        if let authToken {
            var envelope: [String: Any] = ["auth_token": authToken, "request": request]
            if let hostAuthToken { envelope["host_auth_token"] = hostAuthToken }
            body = envelope
        } else {
            body = request
        }
        var data = (try? JSONSerialization.data(withJSONObject: body)) ?? Data("{}".utf8)
        data.append(0x0A)
        return data
    }

    static func op(_ op: AgentActivityUserOp) -> (method: String, args: [String: Any])? {
        switch op {
        case let .stop(id): ("activity_session_stop", ["id": id])
        case let .pause(id): ("activity_session_pause", ["id": id])
        case let .resume(id): ("activity_session_resume", ["id": id])
        // Live watch (`cua.surface.watch`) is not on the host yet; export,
        // open and stop-all are App-side actions.
        case .watch, .export, .openAgent, .openTarget, .stopAll: nil
        }
    }

    private static func date(_ value: Any?) -> Date {
        Date(timeIntervalSince1970: ((value as? NSNumber)?.doubleValue ?? 0) / 1000)
    }

    private static func int(_ value: Any?) -> Int { (value as? NSNumber)?.intValue ?? 0 }
}

private extension String {
    nonisolated var nilIfEmpty: String? { isEmpty ? nil : self }
}
