public import Foundation

/// Read-only access to classic cmux's saved session file.
public nonisolated struct ClassicSessionImporter: Sendable {
    public static let stableBundleIdentifier = "com.cmuxterm.app"
    /// Classic stable and classic NIGHTLY: each saves its own snapshot.
    static let classicBundleIdentifiers = [stableBundleIdentifier, "com.cmuxterm.app.nightly"]
    public let fileURL: URL

    public init(fileURL: URL? = nil, fileManager: FileManager? = nil) {
        if let fileURL { self.fileURL = fileURL }
        else {
            let manager = fileManager ?? FileManager.default
            let support = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? manager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
            self.fileURL = Self.newestSnapshot(in: support)
        }
    }

    init(applicationSupport support: URL) {
        fileURL = Self.newestSnapshot(in: support)
    }

    /// The snapshot classic saved last under `support`, stable's when there
    /// is none.
    static func newestSnapshot(in support: URL) -> URL {
        let candidates = Self.classicBundleIdentifiers.map { support.appendingPathComponent("cmux/session-\($0).json") }
        let saved = candidates.compactMap { url -> (URL, Date)? in
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            return date.map { (url, $0) }
        }
        return saved.max { $0.1 < $1.1 }?.0 ?? candidates[0]
    }

    /// Returns the saved workspaces, or an empty list when classic cmux has no snapshot.
    public func read() throws -> [ClassicSessionWorkspace] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        // concurrency-allow: callers hop to a detached utility task; the synchronous API stays fixture-testable.
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
        let name = Self.name(custom: value["customTitle"] as? String, process: value["processTitle"] as? String,
                             firstTab: panelEntries.first?.1.title, directory: cwd)
        // A snapshot can name a panel twice; the first wins.
        let panelMap = Dictionary(panelEntries, uniquingKeysWith: { first, _ in first })
        guard let layoutValue = value["layout"] as? [String: Any] else {
            var seen = Set<String>()
            let tabs = panelEntries.filter { seen.insert($0.0).inserted }.map { $0.1 }
            return ClassicSessionWorkspace(name: name, workingDirectory: cwd, layout: .pane(ClassicSessionPane(tabs: tabs)))
        }
        let layout = Self.layout(layoutValue, panels: panelMap)
        return ClassicSessionWorkspace(name: name, workingDirectory: cwd, layout: layout)
    }

    /// The user's own title; else classic's process title or the first
    /// tab's, unless it is only a path ("~" for every home-folder shell);
    /// else the folder's name.
    static func name(custom: String?, process: String?, firstTab: String?, directory: String) -> String {
        if let custom, !custom.isEmpty { return custom }
        for title in [process, firstTab] {
            guard let title = title?.trimmingCharacters(in: .whitespaces), !title.isEmpty else { continue }
            if title != "~", !title.hasPrefix("~/"), !title.hasPrefix("/") { return title }
        }
        let folder = URL(fileURLWithPath: directory).lastPathComponent
        return folder.isEmpty || folder == "/" ? "Imported workspace" : folder
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
        // Only panels the snapshot still has become tabs; the selection
        // counts those.
        let resolved = ids.filter { panels[$0] != nil }
        let tabs = resolved.compactMap { panels[$0] }
        let selectedID = (pane["selectedPanelId"] as? String) ?? (pane["selected_panel_id"] as? String)
        let selected = selectedID.flatMap { resolved.firstIndex(of: $0) } ?? 0
        return .pane(ClassicSessionPane(tabs: tabs, selectedTab: selected))
    }
}
