public import Foundation

/// Authority filter for a phone's agent-GUI lane to the Mac's acpmux.
///
/// A denylist, so acpmux methods added later reach the phone without a Mac
/// update (the agent GUI ships in the phone app). It refuses only what would
/// change the daemon itself rather than a conversation: shutting it down,
/// reloading or rewriting its configuration, adding or removing remote
/// hosts, and importing or exporting bundles at arbitrary Mac paths.
public struct AcpmuxLanePolicy: LaneLineAuthority {
    /// Largest request line: a prompt's text; files travel on transfer lanes.
    public static let maximumLineBytes = 8 * 1024 * 1024
    /// ``LaneLineAuthority`` conformance.
    public var maximumLineBytes: Int { Self.maximumLineBytes }

    /// Methods a phone may never call.
    public static let deniedMethods: Set<String> = [
        "_acpmux/shutdown", "_acpmux/reload_config", "_acpmux/peer_add", "_acpmux/peer_remove",
        "_acpmux/import", "_acpmux/export", "_acpmux/set_default_policy",
    ]

    public init() {}

    /// Forwards every JSON-RPC line except a denied method (or `_acpmux/defaults`
    /// that sets or clears), which is answered with a JSON-RPC error.
    public func evaluate(_ line: Data) -> DaemonLanePolicy.Verdict {
        guard line.count <= Self.maximumLineBytes else {
            return .refuse(Self.error(id: nil, message: "request exceeds 8 MiB"))
        }
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            return .refuse(Self.error(id: nil, message: "not a JSON-RPC object"))
        }
        let method = object["method"] as? String ?? ""
        let params = object["params"] as? [String: Any] ?? [:]
        let changesDefaults = method == "_acpmux/defaults" && (params["set"] != nil || params["clear"] != nil)
        if Self.deniedMethods.contains(method) || changesDefaults {
            return .refuse(Self.error(id: object["id"], message: "\(method) is not available from a phone"))
        }
        return .forward
    }

    /// A JSON-RPC 2.0 error answering `id` (a notification gets none, but a
    /// refused notification has nothing to wait for, so the line is harmless).
    static func error(id: Any?, message: String) -> Data {
        let response: [String: Any] = ["jsonrpc": "2.0", "id": id ?? NSNull(), "error": ["code": -32001, "message": message]]
        return (try? JSONSerialization.data(withJSONObject: response, options: [.sortedKeys])) ?? Data()
    }
}
