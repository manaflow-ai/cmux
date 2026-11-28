import CmuxNextSettings
import Foundation

/// The rows Settings draws from `_acpmux/harnesses`: one per harness, by id, with where it came
/// from. Never the command line or env.
nonisolated enum AgentHarnessRows {
    static func rows(_ list: JSONValue?) -> [JSONValue] {
        guard case .object(let harnesses)? = list?["harnesses"] else { return [] }
        let defaultID = list?["defaultHarness"]?.stringValue
        return harnesses.keys.sorted().map { id in
            let entry = harnesses[id] ?? .null
            let source = source(entry)
            var row: [String: JSONValue] = [
                "id": .string(id),
                "name": entry["displayName"] ?? .string(id),
                "kind": entry["kind"] ?? .string("acp"),
                "source": .string(source),
                "removable": .bool(source == "user"),
                "default": .bool(id == defaultID),
            ]
            for key in ["family", "icon", "unavailable", "probeError", "sourcePath"] {
                if let value = entry[key], value != .null { row[key] = value }
            }
            return .object(row)
        }
    }

    /// `user` (a profile file the user owns), `managed`, `cmuxJson`, `acpx` (~/.acpx), `registry`
    /// (an ACP Registry agent on PATH) or `builtIn` (an agent acpmux found on PATH).
    static func source(_ entry: JSONValue) -> String {
        switch entry["source"]?.stringValue {
        case "user-file": return "user"
        case "managed": return "managed"
        case "cmux-json": return "cmuxJson"
        default: break
        }
        let description = entry["description"]?.stringValue ?? ""
        if description.contains("~/.acpx") { return "acpx" }
        if description.localizedCaseInsensitiveContains("registry") { return "registry" }
        return "builtIn"
    }
}
