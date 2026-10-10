import Foundation

// The mount commands of the daemon's app supervisor (capability `apps-v1`,
// plans/cmux-next/app-platform.md section 13.2). An app's own JSON
// (`context`, `payload`) goes on the wire verbatim (``VerbatimFieldsRequest``).

/// `apps-mount`: starts the app's host when needed and streams
/// `apps-scene {mount_id, ops, reset?}` to this connection only.
public struct AppsMountRequest: DaemonRequest, VerbatimFieldsRequest {
    public typealias Response = JSONValue
    public static let command = "apps-mount"

    public var app: String
    public var interface: String
    public var mountID: String
    public var context: JSONValue

    public init(app: String, interface: String, mountID: String, context: JSONValue) {
        self.app = app
        self.interface = interface
        self.mountID = mountID
        self.context = context
    }

    enum CodingKeys: String, CodingKey {
        case app, interface, mountID = "mountId"
    }

    var verbatimFields: [String: JSONValue] { ["context": context] }
}

public struct AppsUnmountRequest: DaemonRequest {
    public typealias Response = JSONValue
    public static let command = "apps-unmount"

    public var mountID: String

    public init(mountID: String) {
        self.mountID = mountID
    }

    enum CodingKeys: String, CodingKey {
        case mountID = "mountId"
    }
}

/// `apps-dispatch`: a user event on a mounted node. Origin `user`: the
/// supervisor mints the gesture token for it.
public struct AppsDispatchRequest: DaemonRequest, VerbatimFieldsRequest {
    public typealias Response = JSONValue
    public static let command = "apps-dispatch"

    public var mountID: String
    public var node: String
    public var event: String
    public var payload: JSONValue
    public var origin: String

    public init(mountID: String, node: String, event: String, payload: JSONValue, origin: String = "user") {
        self.mountID = mountID
        self.node = node
        self.event = event
        self.payload = payload
        self.origin = origin
    }

    enum CodingKeys: String, CodingKey {
        case mountID = "mountId", node, event, origin
    }

    var verbatimFields: [String: JSONValue] { ["payload": payload] }
}
