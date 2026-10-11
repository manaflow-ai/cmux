public import Foundation

/// One chat header quick action as `agent-pane/layout.json` lists it (acpmux
/// header/quickActions.ts): its id and whether a click toggles its panel or opens another.
public nonisolated struct AgentPaneQuickAction: Equatable, Sendable {
    public var id: String
    public var mode: String

    public init(id: String, mode: String) {
        self.id = id
        self.mode = mode
    }

    /// The most a saved list holds.
    static let maximumCount = 16
    static let modes: Set<String> = ["toggle", "open"]

    /// The page's list (`[{id, mode}]`); nil unless every entry is a short letters-only id with a
    /// known mode. The page decides which ids it shows; a stale one is dropped when it reads them.
    static func list(_ value: Any?) -> [AgentPaneQuickAction]? {
        guard let entries = value as? [[String: Any]], entries.count <= maximumCount else { return nil }
        var list: [AgentPaneQuickAction] = []
        for entry in entries {
            guard let id = entry["id"] as? String, (1...32).contains(id.count), id.allSatisfy({ $0.isASCII && $0.isLetter }),
                  let mode = entry["mode"] as? String, modes.contains(mode) else { return nil }
            list.append(AgentPaneQuickAction(id: id, mode: mode))
        }
        return list
    }

    var json: [String: String] { ["id": id, "mode": mode] }
}

extension AgentPaneCustomization {
    /// Writes `list` as `quickActions` in `layout.json` in `directory`, keeping the file's other
    /// keys, creating both when missing. Blocking file IO: call it off the main actor.
    ///
    /// - Throws: When `layout.json` exists but is not a JSON object (the user is midway through
    ///   editing it: it is never overwritten), or when it cannot be written.
    public static func savingQuickActions(_ list: [AgentPaneQuickAction], in directory: URL) throws {
        let file = directory.appending(path: "layout.json")
        var layout: [String: Any] = [:]
        // concurrency-allow: documented as blocking; the App calls it from a @concurrent writer.
        if let data = try? Data(contentsOf: file) {
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: file.path])
            }
            layout = object
        }
        layout["quickActions"] = list.map(\.json)
        let data = try JSONSerialization.data(withJSONObject: layout, options: [.sortedKeys, .prettyPrinted])
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: file, options: .atomic)
    }
}
