import Foundation

/// `column.update` (resource API v2) for a column the app knows by one of its panes: the v1 tree
/// names a column by its handle, the resource op by the column's public split id, which
/// `screen.get` lists in the screen's layout document.
extension DaemonConnection {
    /// Lets the pinned column holding `pane` on `screen` take tabs, or not (`pinned-dock-v1`
    /// `allow_tabs`). Throws when `screen.get` lists no viewport column holding `pane`.
    public func setColumnAllowsTabs(_ allows: Bool, screen: ResourceID, pane: ResourceID) async throws {
        let read = try await resourceRequest({ id in
            ResourceRequestEnvelope(id: id, operation: "screen.get", params: ["screen": .string(screen.rawValue)], idempotencyKey: nil)
        }, as: JSONValue.self)
        guard let column = Self.column(holding: pane.rawValue, in: read["layout"]?["root"]) else {
            throw DaemonError.malformedResponse("screen.get: no viewport column holds \(pane.rawValue)")
        }
        let key = "cmux-next-column-allow-tabs-" + UUID().uuidString.lowercased()
        let params: [String: JSONValue] = ["screen": .string(screen.rawValue), "column": .string(column), "allow_tabs": .bool(allows)]
        _ = try await resourceRequest({ id in
            ResourceRequestEnvelope(id: id, operation: "column.update", params: params, idempotencyKey: key)
        }, as: ResourceMutationResult<JSONValue>.self)
    }

    /// The `column_id` of the viewport column of layout document root `root` whose tree holds pane
    /// `pane`, or nil (no viewport, or no such column).
    static func column(holding pane: String, in root: JSONValue?) -> String? {
        guard root?["kind"]?.stringValue == "viewport" else { return nil }
        return root?["columns"]?.arrayValue?.first { holds(pane, $0["root"]) }?["column_id"]?.stringValue
    }

    private static func holds(_ pane: String, _ node: JSONValue?) -> Bool {
        guard let node else { return false }
        switch node["kind"]?.stringValue {
        case "leaf": return node["pane_id"]?.stringValue == pane
        case "split": return holds(pane, node["first"]) || holds(pane, node["second"])
        case "stack": return node["pane_ids"]?.arrayValue?.contains(.string(pane)) == true
        default: return false
        }
    }
}
