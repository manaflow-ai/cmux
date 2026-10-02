import CmuxNextApps
import CmuxNextDaemon
import Foundation

// The `apps-v1` commands of the daemon's app supervisor
// (plans/cmux-next/app-platform.md section 13.2). Field names become
// snake_case on the wire; JSON payloads (`context`, `payload`, `args`) are
// string-keyed dictionaries, whose keys the wire encoder leaves as they are.
// Every reply decodes as raw JSON and is read by `CmuxNextApps`.

struct AppsListRequest: DaemonRequest {
    typealias Response = JSONValue
    static let command = "apps-list"
}

struct AppsSetRequest: DaemonRequest {
    typealias Response = JSONValue
    static let command = "apps-set"
    var idempotencyKey: String
    var app: String
    var origin: String
    var installed: Bool?
    var enabled: Bool?
    var hidden: Bool?
    var sandboxed: Bool?
    var grant: Grant?

    struct Grant: Encodable {
        var scope: String
        var granted: Bool
    }

    init(app: String, change: AppChange, origin: AppOrigin, idempotencyKey: String) {
        self.idempotencyKey = idempotencyKey
        self.app = app
        self.origin = origin.rawValue
        installed = change.installed
        enabled = change.enabled
        hidden = change.hidden
        sandboxed = change.sandboxed
        grant = change.grant.map { Grant(scope: $0.scope, granted: $0.granted) }
    }
}

struct AppsMountRequest: DaemonRequest {
    typealias Response = JSONValue
    static let command = "apps-mount"
    var app: String
    var interface: String
    var mountID: String
    var context: JSONValue
}
