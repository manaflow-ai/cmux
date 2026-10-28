import Foundation

// A web pane's door to the app supervisor (plans/cmux-next/custom-panes-DESIGN.md
// sections 3 and 6.4; cmux-tui-core `apps/web_calls.rs`, `apps/registry.rs`). Only
// the verified cmux app connection that is not bound to an agent may send them.

/// `apps-web-call`: one `cmux.call(op, params)` of an app's web pane, decided like
/// a call from the app's own host (grant, sandbox, no gesture). Answers the op's
/// result (`{value}` for a read, the mutation result for a write).
public struct AppsWebCallRequest: DaemonRequest, VerbatimFieldsRequest {
    public typealias Response = JSONValue
    public static let command = "apps-web-call"

    public var app: String
    public var op: String
    /// The page's own JSON, sent verbatim.
    public var args: JSONValue
    public var idempotencyKey: String?

    public init(app: String, op: String, args: JSONValue, idempotencyKey: String? = nil) {
        self.app = app
        self.op = op
        self.args = args
        self.idempotencyKey = idempotencyKey
    }

    enum CodingKeys: String, CodingKey {
        case app, op, idempotencyKey
    }

    var verbatimFields: [String: JSONValue] { ["args": args] }
}

/// `apps-web-log`: one console line of an app's web pane into its log ring.
public struct AppsWebLogRequest: DaemonRequest {
    public typealias Response = JSONValue
    public static let command = "apps-web-log"

    public var app: String
    public var level: String
    public var message: String

    public init(app: String, level: String, message: String) {
        self.app = app
        self.level = level
        self.message = message
    }
}

/// `apps-store {op: "cmux.apps.registry.put"}`: an approved App Store bundle for the
/// supervisor to check against the listing's hash and add to its catalog.
public struct AppsRegistryPutRequest: DaemonRequest, VerbatimFieldsRequest {
    public typealias Response = JSONValue
    public static let command = "apps-store"

    public var app: String
    public var version: String
    public var sha256: String
    /// Package path to its bytes, base64.
    public var files: [String: String]

    public init(app: String, version: String, sha256: String, files: [String: String]) {
        self.app = app
        self.version = version
        self.sha256 = sha256
        self.files = files
    }

    enum CodingKeys: String, CodingKey {
        case op
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("cmux.apps.registry.put", forKey: .op)
    }

    /// File paths are keys the snake case strategy must not touch.
    var verbatimFields: [String: JSONValue] {
        ["args": .object(["app": .string(app), "version": .string(version), "sha256": .string(sha256),
                          "files": .object(files.mapValues(JSONValue.string))])]
    }
}
