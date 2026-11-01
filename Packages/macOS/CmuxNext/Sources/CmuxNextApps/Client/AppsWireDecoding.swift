public import CmuxNextDaemon
import Foundation

/// Reads the app supervisor's events (`event` plus top-level fields) and replies (`apps-v1`,
/// plans/cmux-next/app-platform.md 13.2).
public nonisolated struct AppsWireDecoding {
    public init() {}

    /// The transport event of daemon event `name`, nil for an event the client does not use.
    public func event(name: String, payload: CmuxNextDaemon.JSONValue) -> AppsTransportEvent? {
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
            return .mountFailed(mountID: mount, reason: json["reason"]?.stringValue ?? AppsStrings.mountFailed)
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

    /// The `apps-list` reply.
    public func list(_ value: CmuxNextDaemon.JSONValue) -> AppsListReply {
        let json = AppJSON(value)
        return AppsListReply(revision: json["revision"]?.numberValue.flatMap { UInt64(exactly: $0) },
                             apps: (json["apps"]?.arrayValue ?? []).compactMap(AppRecord.init(json:)))
    }

    /// The `apps-logs` reply's lines, numbered from 1.
    public func logs(_ value: CmuxNextDaemon.JSONValue) -> [AppLogLine] {
        (AppJSON(value)["lines"]?.arrayValue ?? []).enumerated().map { index, line in
            AppLogLine(id: index + 1, date: line["ts_ms"]?.numberValue.map { Date(timeIntervalSince1970: $0 / 1000) },
                       level: line["level"]?.stringValue ?? "info", message: line["message"]?.stringValue ?? "")
        }
    }
}
