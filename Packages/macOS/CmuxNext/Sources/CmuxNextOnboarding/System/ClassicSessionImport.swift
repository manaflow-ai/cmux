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

    /// The Claude Code and Codex chats classic's terminals had open, as
    /// `AgentChat.id`s; empty when classic cmux has no snapshot.
    public func readOpenChats() throws -> Set<String> {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        // concurrency-allow: callers hop to a detached utility task; the synchronous API stays fixture-testable.
        return try openChats(Data(contentsOf: fileURL, options: [.mappedIfSafe]))
    }

    /// Each terminal's `agent` (classic's restorable agent session) that is
    /// a Claude Code or Codex chat.
    public func openChats(_ data: Data) throws -> Set<String> {
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        let windows = (root["windows"] as? [[String: Any]]) ?? []
        let panels = windows.flatMap { window -> [[String: Any]] in
            let manager = window["tabManager"] as? [String: Any] ?? window["tab_manager"] as? [String: Any] ?? [:]
            return ((manager["workspaces"] as? [[String: Any]]) ?? []).flatMap { ($0["panels"] as? [[String: Any]]) ?? [] }
        }
        return Set(panels.compactMap { panel -> String? in
            guard let agent = (panel["terminal"] as? [String: Any])?["agent"] as? [String: Any],
                  let session = agent["sessionId"] as? String, !session.isEmpty else { return nil }
            let app: AgentApp? = switch agent["kind"] as? String {
            case "claude": .claudeCode
            case "codex": .codex
            default: nil
            }
            return app.map { "\($0.rawValue):\(session)" }
        })
    }

    /// Decodes only topology, names, directories, and titles from a classic snapshot.
    public func decode(_ data: Data) throws -> [ClassicSessionWorkspace] {
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        let workspaces = ((root["windows"] as? [[String: Any]]) ?? []).flatMap { window in
            let manager = window["tabManager"] as? [String: Any] ?? window["tab_manager"] as? [String: Any] ?? [:]
            return (manager["workspaces"] as? [[String: Any]]) ?? []
        }
        let names = Self.names(workspaces.map(Self.clues))
        return zip(workspaces, names).map { Self.workspace($0, name: $1) }
    }

    private static func directory(_ value: [String: Any]) -> String {
        (value["currentDirectory"] as? String) ?? (value["current_directory"] as? String) ?? NSHomeDirectory()
    }

    private static func workspace(_ value: [String: Any], name: String) -> ClassicSessionWorkspace {
        let cwd = Self.directory(value)
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

    /// What can tell a classic workspace apart, most telling first.
    nonisolated struct NameClues: Equatable {
        var custom: String?
        /// Its process and tab titles that are more than a path ("~" for
        /// every home-folder shell): a running command or a tab's title.
        var titles: [String]
        var agent: String?
        var branch: String?
        var folder: String
    }

    static func clues(_ value: [String: Any]) -> NameClues {
        let panels = (value["panels"] as? [[String: Any]]) ?? []
        let titles = ([value["processTitle"]] + panels.flatMap { [$0["customTitle"], $0["title"]] })
            .compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0 != "~" && !$0.hasPrefix("~/") && !$0.hasPrefix("/") }
        let agent = panels.lazy
            .compactMap { (($0["terminal"] as? [String: Any])?["agent"] as? [String: Any])?["kind"] as? String }
            .first { !$0.isEmpty }
        let branch = ([value] + panels).lazy
            .compactMap { ($0["gitBranch"] as? [String: Any])?["branch"] as? String }
            .first { !$0.isEmpty }
        let folder = URL(fileURLWithPath: Self.directory(value)).lastPathComponent
        return NameClues(custom: (value["customTitle"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                         titles: titles, agent: agent, branch: branch,
                         folder: folder.isEmpty || folder == "/" ? "Imported workspace" : folder)
    }

    /// The user's own title; else a running command or tab title, the
    /// agent it ran, or the folder's name. Names several workspaces share
    /// take each one's branch, and a number only as the last resort.
    static func names(_ clues: [NameClues]) -> [String] {
        var names = clues.map { $0.custom ?? $0.titles.first ?? $0.agent ?? $0.folder }
        let counts = Dictionary(names.map { ($0, 1) }, uniquingKeysWith: +)
        for index in names.indices where counts[names[index], default: 0] > 1 && clues[index].custom == nil {
            if let branch = clues[index].branch, branch != names[index] { names[index] += " · \(branch)" }
        }
        var seen: [String: Int] = [:]
        return names.map { name in
            seen[name, default: 0] += 1
            let count = seen[name, default: 1]
            return count == 1 ? name : "\(name) \(count)"
        }
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
