import Foundation

// The install mirror and log commands of the daemon's app supervisor
// (capability `apps-v1`, plans/cmux-next/app-platform.md section 13.2;
// cmux-tui-core `server/apps.rs`). Replies decode as raw JSON; the apps
// client in CmuxNextApps reads them. Mounts: AppsMountRequests.swift.

/// `apps-list`: `{revision, apps: [record]}`.
public struct AppsListRequest: DaemonRequest {
    public typealias Response = JSONValue
    public static let command = "apps-list"

    public init() {}
}

/// `apps-set`: one change of one app; answers the app's record after the
/// commit (with the commit's `revision`). Every change needs the verified
/// cmux app connection (Gate A2), whatever `origin` says.
public struct AppsSetRequest: DaemonRequest {
    public typealias Response = JSONValue
    public static let command = "apps-set"

    public struct Grant: Encodable, Sendable {
        public var scope: String
        public var granted: Bool

        public init(scope: String, granted: Bool) {
            self.scope = scope
            self.granted = granted
        }
    }

    public var idempotencyKey: String
    public var app: String
    public var origin: String
    public var installed: Bool?
    public var enabled: Bool?
    public var hidden: Bool?
    public var sandboxed: Bool?
    public var grant: Grant?

    public init(idempotencyKey: String, app: String, origin: String, installed: Bool? = nil, enabled: Bool? = nil,
                hidden: Bool? = nil, sandboxed: Bool? = nil, grant: Grant? = nil) {
        self.idempotencyKey = idempotencyKey
        self.app = app
        self.origin = origin
        self.installed = installed
        self.enabled = enabled
        self.hidden = hidden
        self.sandboxed = sandboxed
        self.grant = grant
    }
}

/// `apps-logs`: `{lines: [{level, message, ts_ms}]}`; `follow` streams `apps-log` events.
public struct AppsLogsRequest: DaemonRequest {
    public typealias Response = JSONValue
    public static let command = "apps-logs"

    public var app: String
    public var follow: Bool

    public init(app: String, follow: Bool) {
        self.app = app
        self.follow = follow
    }
}
