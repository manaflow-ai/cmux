public import Foundation

/// Errors produced while reading a classic cmux session snapshot.
public enum ClassicSessionImportError: Error, LocalizedError, Equatable, Sendable {
    case snapshotTooLarge(actualBytes: Int, maximumBytes: Int)

    public var errorDescription: String? {
        switch self {
        case .snapshotTooLarge:
            "The classic cmux session snapshot is too large to read."
        }
    }
}

/// Read-only access to classic cmux's saved session file.
public nonisolated struct ClassicSessionImporter: Sendable {
    public static let stableBundleIdentifier = "com.cmuxterm.app"
    /// Snapshots are topology-only input, so a generous cap prevents a corrupt
    /// or hostile file from consuming unbounded memory during onboarding.
    public static let maximumSnapshotBytes = 64 * 1024 * 1024
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
        let directory = support.appendingPathComponent("cmux", isDirectory: true)
        // Enumerate names, then append them to the caller's URL. This keeps
        // temporary fixture paths stable when `/var` is symlinked to `/private/var`.
        let candidates = ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
            .filter { name in
                guard name.hasSuffix(".json"), name.hasPrefix("session-") else { return false }
                let bundle = String(name.dropFirst("session-".count).dropLast(".json".count))
                return Self.isClassicBundleIdentifier(bundle)
            }
            .map { directory.appendingPathComponent($0) }
        let fallback = directory.appendingPathComponent("session-\(stableBundleIdentifier).json")
        let saved = candidates.compactMap { url -> (URL, Date)? in
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            return date.map { (url, $0) }
        }
        return saved.max { $0.1 < $1.1 }?.0 ?? fallback
    }

    private static func isClassicBundleIdentifier(_ bundleIdentifier: String) -> Bool {
        let channels = ["com.cmuxterm.app", "com.cmuxterm.app.nightly", "com.cmuxterm.app.rc",
                        "com.cmuxterm.app.staging", "com.cmuxterm.app.debug"]
        return channels.contains(bundleIdentifier) || channels.dropFirst().contains { bundleIdentifier.hasPrefix($0 + ".") }
    }

    /// Returns the saved workspaces, or an empty list when classic cmux has no snapshot.
    public func read() throws -> [ClassicSessionWorkspace] {
        guard let data = try readData() else { return [] }
        return try decode(data)
    }

    /// The saved workspaces for Import Workspaces from Classic cmux: a local
    /// folder that is gone (a deleted project, a cleared /tmp) becomes the home
    /// folder, since no terminal can start in it. Only the import checks the
    /// folders; `read()` stays free of file checks that could ask for privacy
    /// access at launch. SSH and Cloud VM folders are on their hosts.
    public func readForImport() throws -> [ClassicSessionWorkspace] {
        try read().map { saved in
            guard saved.remote == nil, saved.cloudVM == nil else { return saved }
            return saved.openingMissingFolders(in: NSHomeDirectory()) { path in
                var isFolder: ObjCBool = false
                return FileManager.default.fileExists(atPath: path, isDirectory: &isFolder) && isFolder.boolValue
            }
        }
    }

    private func readData() throws -> Data? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        if let size = (attributes[.size] as? NSNumber)?.intValue,
           size > Self.maximumSnapshotBytes {
            throw ClassicSessionImportError.snapshotTooLarge(actualBytes: size, maximumBytes: Self.maximumSnapshotBytes)
        }
        // concurrency-allow: callers hop to a detached utility task; the synchronous API stays fixture-testable.
        return try Data(contentsOf: fileURL, options: [.mappedIfSafe])
    }

    /// Decodes topology, names, directories, titles, pages, agent sessions,
    /// scrollback and where each workspace ran from a classic snapshot.
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
            return Self.tab(panel).map { (id, $0) }
        }
        // Panels nothing here can show (markdown, file preview) stay in classic.
        let leftOutPanels = panels.contains { !["terminal", "browser"].contains($0["type"] as? String ?? "terminal") }
        // A snapshot can name a panel twice; the first wins.
        let panelMap = Dictionary(panelEntries, uniquingKeysWith: { first, _ in first })
        guard let layoutValue = value["layout"] as? [String: Any] else {
            var seen = Set<String>()
            let tabs = panelEntries.filter { seen.insert($0.0).inserted }.map { $0.1 }
            return ClassicSessionWorkspace(name: name, workingDirectory: cwd, layout: .pane(ClassicSessionPane(tabs: tabs)),
                                           remote: Self.remote(value), cloudVM: Self.cloudVM(value), leftOutPanels: leftOutPanels)
        }
        let layout = Self.layout(layoutValue, panels: panelMap)
        return ClassicSessionWorkspace(name: name, workingDirectory: cwd, layout: layout,
                                       remote: Self.remote(value), cloudVM: Self.cloudVM(value), leftOutPanels: leftOutPanels)
    }

    /// A terminal or browser panel as a tab; nil for a panel nothing here can
    /// show (markdown, file preview). Old snapshots name no type.
    private static func tab(_ panel: [String: Any]) -> ClassicSessionTab? {
        switch panel["type"] as? String ?? "terminal" {
        case "terminal":
            let terminal = panel["terminal"] as? [String: Any]
            let directory = terminal?["workingDirectory"] as? String ?? terminal?["working_directory"] as? String
                ?? panel["directory"] as? String ?? panel["working_directory"] as? String
            return ClassicSessionTab(workingDirectory: directory, title: panel["customTitle"] as? String ?? panel["title"] as? String,
                                     agent: Self.agent(terminal?["agent"] as? [String: Any], directory: directory)
                                        ?? Self.endedAgent(terminal?["resumeBinding"] as? [String: Any], directory: directory),
                                     scrollback: (terminal?["scrollback"] as? String).flatMap { $0.isEmpty ? nil : $0 })
        case "browser":
            let browser = panel["browser"] as? [String: Any]
            guard let url = browser?["urlString"] as? String ?? browser?["url_string"] as? String, !url.isEmpty else { return nil }
            // Only the person's own title: a page's title is the page's to set.
            return ClassicSessionTab(workingDirectory: nil, title: panel["customTitle"] as? String, url: url)
        default:
            return nil
        }
    }

    /// A Claude Code or Codex session classic recorded; other agents have no
    /// acpmux harness to resume them.
    private static func agent(_ value: [String: Any]?, directory: String?) -> ClassicSessionAgent? {
        guard let value, let kind = value["kind"] as? String, ["claude", "codex"].contains(kind),
              let session = value["sessionId"] as? String ?? value["session_id"] as? String, !session.isEmpty else { return nil }
        return ClassicSessionAgent(harness: kind, sessionID: session,
                                   workingDirectory: value["workingDirectory"] as? String ?? value["working_directory"] as? String ?? directory)
    }

    /// The session of an agent that exited: classic then keeps only its
    /// `resumeBinding` (`checkpointId` is the session id). Only a binding the
    /// agent's own hook recorded names a session, as in classic; one from the
    /// CLI, process detection or a session import does not. A persistent SSH
    /// launch's session is on its host, not this Mac.
    private static func endedAgent(_ binding: [String: Any]?, directory: String?) -> ClassicSessionAgent? {
        guard let binding, binding["source"] as? String == "agent-hook",
              ((binding["launchFlavor"] as? [String: Any])?["kind"] as? String ?? "local") == "local",
              let kind = binding["kind"] as? String, ["claude", "codex"].contains(kind),
              let session = binding["checkpointId"] as? String, !session.isEmpty else { return nil }
        return ClassicSessionAgent(harness: kind, sessionID: session, workingDirectory: binding["cwd"] as? String ?? directory)
    }

    /// An SSH workspace's host. A websocket `remote` is an older Cloud VM
    /// (``cloudVM(_:)``), not SSH.
    private static func remote(_ value: [String: Any]) -> ClassicSessionRemote? {
        guard let remote = value["remote"] as? [String: Any], legacyCloudVM(remote) == nil,
              (remote["transport"] as? String ?? "ssh") == "ssh",
              let destination = (remote["destination"] as? String)?.trimmingCharacters(in: .whitespaces),
              !destination.isEmpty, !destination.hasPrefix("-") else { return nil }
        return ClassicSessionRemote(destination: destination, port: (remote["port"] as? NSNumber)?.intValue)
    }

    /// The Cloud VM a workspace ran on: `cloudVM`, or an older one saved as
    /// a websocket `remote` with `managedCloudVMID`.
    private static func cloudVM(_ value: [String: Any]) -> String? {
        if let vm = value["cloudVM"] as? [String: Any] ?? value["cloud_vm"] as? [String: Any] {
            return vm["vmID"] as? String ?? vm["vm_id"] as? String ?? ""
        }
        return (value["remote"] as? [String: Any]).flatMap(legacyCloudVM)
    }

    private static func legacyCloudVM(_ remote: [String: Any]) -> String? {
        let id = (remote["managedCloudVMID"] as? String ?? remote["managed_cloud_vm_id"] as? String)?
            .trimmingCharacters(in: .whitespaces)
        if let id, !id.isEmpty { return id }
        return remote["transport"] as? String == "websocket" ? "" : nil
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
            // A side with no tab left closes up; the other takes its space.
            if case .pane(let pane) = second, pane.tabs.isEmpty { return first }
            if case .pane(let pane) = first, pane.tabs.isEmpty { return second }
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
