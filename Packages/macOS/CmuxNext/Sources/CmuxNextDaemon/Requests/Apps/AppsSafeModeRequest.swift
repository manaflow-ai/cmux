import Foundation

/// `apps-safe-mode {op, args, origin}` (cmux-tui-core `apps/safe_mode.rs`,
/// docs/cmux-next/extensions/safe-mode.md): `safe_mode.get`, `safe_mode.set {on}` (leaving needs
/// origin `user`), `safe_mode.launch_began` and `safe_mode.launch_settled {reason}` (the launch
/// ops only from the verified cmux app connection). The reply is the safe mode as JSON.
public struct AppsSafeModeRequest: DaemonRequest, VerbatimFieldsRequest {
    public typealias Response = JSONValue
    public static let command = "apps-safe-mode"

    public var op: String
    public var args: JSONValue
    /// nil sends none (the daemon reads `script`).
    public var origin: AppsRunRequest.Origin?

    public init(op: String, args: JSONValue = .object([:]), origin: AppsRunRequest.Origin? = nil) {
        self.op = op
        self.args = args
        self.origin = origin
    }

    enum CodingKeys: String, CodingKey { case op, origin }
    var verbatimFields: [String: JSONValue] { ["args": args] }
}
