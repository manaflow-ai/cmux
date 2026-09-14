import Foundation

/// Accumulates the installed provider's paginated model catalog for the GUI.
struct CodexAppServerModelCatalog {
    var requestID: Int?
    private(set) var models: [[String: Any]] = []
    private var modelIDs: Set<String> = []
    private var cursors: Set<String> = []

    mutating func append(_ result: [String: Any]) -> String? {
        for entry in result["data"] as? [[String: Any]] ?? [] {
            guard entry["hidden"] as? Bool != true,
                  let id = (entry["model"] as? String) ?? (entry["id"] as? String),
                  !id.isEmpty, modelIDs.insert(id).inserted else { continue }
            let efforts = (entry["supportedReasoningEfforts"] as? [[String: Any]] ?? [])
                .compactMap { $0["reasoningEffort"] as? String }
            models.append([
                "id": id,
                "providerId": "codex",
                "displayName": (entry["displayName"] as? String) ?? id,
                "reasoningEfforts": efforts,
                "defaultReasoningEffort": (entry["defaultReasoningEffort"] as? String) ?? "default",
                "isDefault": entry["isDefault"] as? Bool ?? false
            ])
        }
        guard let cursor = result["nextCursor"] as? String,
              !cursor.isEmpty, cursors.insert(cursor).inserted else { return nil }
        return cursor
    }
}
