import CmuxNextApps
import CmuxNextDaemon
import Foundation

// `apps-logs`, JSON conversion, and the readers of supervisor replies and events.

struct AppsLogsRequest: DaemonRequest {
    typealias Response = JSONValue
    static let command = "apps-logs"
    var app: String
    var follow: Bool
}

/// Daemon JSON and app JSON have the same shape.
extension AppJSON {
    init(_ value: JSONValue) {
        switch value {
        case .null: self = .null
        case .bool(let v): self = .bool(v)
        case .number(let v): self = .number(v)
        case .string(let v): self = .string(v)
        case .array(let v): self = .array(v.map(AppJSON.init))
        case .object(let v): self = .object(v.mapValues(AppJSON.init))
        }
    }

    var daemonValue: JSONValue {
        switch self {
        case .null: .null
        case .bool(let v): .bool(v)
        case .number(let v): .number(v)
        case .string(let v): .string(v)
        case .array(let v): .array(v.map(\.daemonValue))
        case .object(let v): .object(v.mapValues(\.daemonValue))
        }
    }
}

/// Reads the supervisor's events (`event` plus top-level fields).
enum AppsEventDecoding {
    static func event(name: String, payload: JSONValue) -> AppsTransportEvent? {
        let json = AppJSON(payload)
        let date = json["ts_ms"]?.numberValue.map { Date(timeIntervalSince1970: $0 / 1000) }
        switch name {
        case "apps-changed":
            return .changed(revision: json["revision"]?.numberValue.flatMap { UInt64(exactly: $0) })
        case "apps-scene":
            guard let mount = json["mount_id"]?.stringValue else { return nil }
            return .scene(mountID: mount, ops: AppSceneOp.batch(json["ops"] ?? .array([])), reset: json["reset"]?.boolValue == true)
        case "apps-mount-failed":
            guard let mount = json["mount_id"]?.stringValue else { return nil }
            return .mountFailed(mountID: mount, reason: json["reason"]?.stringValue ?? "mount failed")
        case "apps-host":
            guard let app = json["app"]?.stringValue, let state = json["state"]?.stringValue.flatMap(AppHostState.init(rawValue:)) else { return nil }
            return .host(app: app, state: state, reason: json["reason"]?.stringValue)
        case "apps-log":
            guard let app = json["app"]?.stringValue else { return nil }
            return .log(app: app, level: json["level"]?.stringValue ?? "info", message: json["message"]?.stringValue ?? "", date: date)
        default:
            return nil
        }
    }

    static func list(_ value: JSONValue) -> AppsListReply {
        let json = AppJSON(value)
        return AppsListReply(revision: json["revision"]?.numberValue.flatMap { UInt64(exactly: $0) },
                             apps: (json["apps"]?.arrayValue ?? []).compactMap(AppRecord.init(json:)))
    }

    static func logs(_ value: JSONValue) -> [AppLogLine] {
        (AppJSON(value)["lines"]?.arrayValue ?? []).enumerated().map { index, line in
            AppLogLine(id: index + 1, date: line["ts_ms"]?.numberValue.map { Date(timeIntervalSince1970: $0 / 1000) },
                       level: line["level"]?.stringValue ?? "info", message: line["message"]?.stringValue ?? "")
        }
    }
}
