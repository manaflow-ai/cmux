import CmuxNextApps
import CmuxNextDaemon
import Foundation

// `apps-v1` commands on a mount and app ops (see AppsRequests.swift).

struct AppsUnmountRequest: DaemonRequest {
    typealias Response = JSONValue
    static let command = "apps-unmount"
    var mountID: String
}

struct AppsDispatchRequest: DaemonRequest {
    typealias Response = JSONValue
    static let command = "apps-dispatch"
    var mountID: String
    var node: String
    var event: String
    var payload: JSONValue
    /// User events only: the supervisor mints the gesture token for them.
    var origin = AppOrigin.user.rawValue
}

struct AppsRunRequest: DaemonRequest {
    typealias Response = JSONValue
    static let command = "apps-run"
    var app: String
    var op: String
    var args: JSONValue
    var idempotencyKey: String
}
