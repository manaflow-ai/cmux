public import Foundation

/// Pane positions decoded from a daemon screen's leaf/split/stack/viewport layout.
public struct RemoteWorkspacePaneOrder: Sendable {
    /// First-occurrence pane positions; absent panes have no invented position.
    public let positions: [String: Int]

    /// Reads a layout document, preserving first occurrence and ignoring unknown nodes.
    public nonisolated init(document: Any?) {
        var positions: [String: Int] = [:]
        func record(_ value: Any?) {
            guard let value = value as? String else { return }
            let paneID = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !paneID.isEmpty, positions[paneID] == nil else { return }
            positions[paneID] = positions.count
        }
        func visit(_ value: Any?) {
            guard let node = value as? [String: Any] else { return }
            switch node["kind"] as? String {
            case "leaf": record(node["pane_id"])
            case "split":
                visit(node["first"])
                visit(node["second"])
            case "stack":
                for paneID in (node["pane_ids"] as? [Any]) ?? [] { record(paneID) }
            case "viewport":
                for column in (node["columns"] as? [[String: Any]]) ?? [] { visit(column["root"]) }
            default: break
            }
        }
        visit((document as? [String: Any])?["root"])
        self.positions = positions
    }

    /// Uses the same decoder for opaque incremental screen-layout payloads.
    public nonisolated init(data: Data?) {
        self.init(document: data.flatMap { try? JSONSerialization.jsonObject(with: $0) })
    }
}
