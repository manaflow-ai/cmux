public import Foundation

/// Read-only access to classic cmux's saved session file.
public nonisolated struct ClassicSessionImporter: Sendable {
    public static let stableBundleIdentifier = "com.cmuxterm.app"
    public let fileURL: URL

    public init(fileURL: URL? = nil, fileManager: FileManager? = nil) {
        if let fileURL { self.fileURL = fileURL }
        else {
            let manager = fileManager ?? FileManager.default
            let support = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? manager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
            self.fileURL = support.appendingPathComponent("cmux/session-\(Self.stableBundleIdentifier).json")
        }
    }

    /// Returns the saved workspaces, or an empty list when classic cmux has no snapshot.
    public func read() throws -> [ClassicSessionWorkspace] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
        return try decode(data)
    }

    /// Decodes only topology, names, directories, and titles from a classic snapshot.
    public func decode(_ data: Data) throws -> [ClassicSessionWorkspace] {
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        let windows = (root["windows"] as? [[String: Any]]) ?? []
        return windows.flatMap { window in
            let manager = window["tabManager"] as? [String: Any] ?? window["tab_manager"] as? [String: Any] ?? [:]
            let workspaces = (manager["workspaces"] as? [[String: Any]]) ?? []
            return workspaces.compactMap(Self.workspace)
        }
    }

    private static func workspace(_ value: [String: Any]) -> ClassicSessionWorkspace? {
        let name = (value["customTitle"] as? String) ?? (value["processTitle"] as? String) ?? "Imported workspace"
        let cwd = (value["currentDirectory"] as? String) ?? (value["current_directory"] as? String) ?? NSHomeDirectory()
        let panels = (value["panels"] as? [[String: Any]]) ?? []
        let panelEntries = panels.compactMap { panel -> (String, ClassicSessionTab)? in
            guard let id = panel["id"] as? String else { return nil }
            let terminal = panel["terminal"] as? [String: Any]
            return (id, ClassicSessionTab(workingDirectory: terminal?["workingDirectory"] as? String
                                          ?? terminal?["working_directory"] as? String
                                          ?? panel["directory"] as? String
                                          ?? panel["working_directory"] as? String,
                                          title: panel["customTitle"] as? String ?? panel["title"] as? String))
        }
        let panelMap = Dictionary(uniqueKeysWithValues: panelEntries)
        guard let layoutValue = value["layout"] as? [String: Any] else {
            return ClassicSessionWorkspace(name: name, workingDirectory: cwd, layout: .pane(ClassicSessionPane(tabs: panelEntries.map { $0.1 })))
        }
        let layout = Self.layout(layoutValue, panels: panelMap)
        return ClassicSessionWorkspace(name: name, workingDirectory: cwd, layout: layout)
    }

    private static func layout(_ value: [String: Any], panels: [String: ClassicSessionTab]) -> ClassicSessionLayout {
        if value["type"] as? String == "split" {
            let split = value["split"] as? [String: Any] ?? value
            let orientation = ClassicSessionLayout.Orientation(rawValue: split["orientation"] as? String ?? "horizontal") ?? .horizontal
            let ratio = max(0.05, min(0.95, split["dividerPosition"] as? Double ?? split["ratio"] as? Double ?? 0.5))
            let first = layout(split["first"] as? [String: Any] ?? [:], panels: panels)
            let second = layout(split["second"] as? [String: Any] ?? [:], panels: panels)
            return .split(orientation: orientation, ratio: ratio, first: first, second: second)
        }
        let pane = value["pane"] as? [String: Any] ?? value
        let ids = (pane["panelIds"] as? [String]) ?? (pane["panel_ids"] as? [String]) ?? []
        let tabs = ids.compactMap { panels[$0] }
        let selectedID = (pane["selectedPanelId"] as? String) ?? (pane["selected_panel_id"] as? String)
        let selected = selectedID.flatMap { ids.firstIndex(of: $0) } ?? 0
        return .pane(ClassicSessionPane(tabs: tabs, selectedTab: selected))
    }
}
