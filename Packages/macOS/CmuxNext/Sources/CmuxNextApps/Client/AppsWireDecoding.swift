public import CmuxNextDaemon
import Foundation

/// Reads the supervisor's events (`event` plus top-level fields) and replies.
public nonisolated struct AppsWireDecoding {
    /// Creates a decoder for app supervisor events and replies.
    public init() {}

    /// Decodes one supervisor event; unknown or malformed events have no effect.
    public func event(name: String, payload: CmuxNextDaemon.JSONValue) -> AppsTransportEvent? {
        let json = AppJSON(payload)
        let date = json["ts_ms"]?.numberValue.map { Date(timeIntervalSince1970: $0 / 1000) }
        switch name {
        case "apps-changed":
            return .changed(revision: json["revision"]?.numberValue.flatMap { UInt64(exactly: $0) },
                            app: json["app"]?.stringValue, transaction: json["transaction"]?.stringValue)
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

    /// Decodes the supervisor's current catalog snapshot.
    public func list(_ value: CmuxNextDaemon.JSONValue) -> AppsListReply {
        let json = AppJSON(value)
        return AppsListReply(revision: json["revision"]?.numberValue.flatMap { UInt64(exactly: $0) },
                             apps: (json["apps"]?.arrayValue ?? []).compactMap(AppRecord.init(json:)))
    }

    /// Decodes the bounded log-ring reply in its original order.
    public func logs(_ value: CmuxNextDaemon.JSONValue) -> [AppLogLine] {
        (AppJSON(value)["lines"]?.arrayValue ?? []).enumerated().map { index, line in
            AppLogLine(id: index + 1, date: line["ts_ms"]?.numberValue.map { Date(timeIntervalSince1970: $0 / 1000) },
                       level: line["level"]?.stringValue ?? "info", message: line["message"]?.stringValue ?? "")
        }
    }
}
