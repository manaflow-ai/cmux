public import Foundation

/// Errors produced while reading a classic cmux session snapshot.
public enum ClassicSessionImportError: Error, LocalizedError, Equatable, Sendable {
    case snapshotTooLarge(actualBytes: Int, maximumBytes: Int)
    /// The file is JSON but not a session object (a damaged or foreign file).
    case notASnapshot
    case snapshotTooComplex

    public var errorDescription: String? {
        switch self {
        case .snapshotTooLarge:
            "The classic cmux session snapshot is too large to read."
        case .notASnapshot:
            "The classic cmux session file is not a session snapshot."
        case .snapshotTooComplex:
            "The classic cmux session snapshot has too much saved state to import safely."
        }
    }
}

/// Read-only access to classic cmux's saved session file.
public nonisolated struct ClassicSessionImporter: Sendable {
    public static let stableBundleIdentifier = "com.cmuxterm.app"
    /// A cap so a corrupt or hostile file cannot take unbounded memory. Classic
    /// itself reads its session with no cap, and a heavy quit save (classic
    /// keeps 400,000 characters of scrollback per terminal, up to 12 windows
    /// of 128 workspaces) passes 64 MB at about 150 full terminals, so the
    /// cap sits far above what classic writes in practice.
    public static let maximumSnapshotBytes = 512 * 1024 * 1024
    static let maximumWindows = 64
    static let maximumWorkspaces = 1_000
    static let maximumPanelsPerWorkspace = 256
    static let maximumTotalPanels = 4_096
    static let maximumLayoutDepth = 64
    static let maximumLayoutNodes = 8_192
    static let maximumJSONNodes = 100_000
    static let maximumEncodedJSONTokens = 200_000
    static let maximumJSONDepth = 128
    static let maximumMetadataStringBytes = 64 * 1024
    static let maximumEncodedStringBytes = 4 * 1024 * 1024
    static let maximumTotalEncodedStringBytes = 160 * 1024 * 1024
    static let maximumScrollbackBytes = 4 * 1024 * 1024
    static let maximumTotalScrollbackBytes = 128 * 1024 * 1024
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
        return try decodeSnapshot(data, checkpoints: Self.checkpointFolder(for: fileURL)).workspaces
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
        try Self.readData(at: fileURL, maximumBytes: Self.maximumSnapshotBytes)
    }

    /// The whole saved session, window by window; nil when classic has no snapshot.
    public func readSnapshot() throws -> ClassicSessionSnapshot? {
        guard let data = try readData() else { return nil }
        return try decodeSnapshot(data, checkpoints: Self.checkpointFolder(for: fileURL))
    }

    /// Decodes topology, names, directories, titles, pages, agent sessions,
    /// scrollback and where each workspace ran from a classic snapshot.
    public func decode(_ data: Data) throws -> [ClassicSessionWorkspace] {
        try decodeSnapshot(data).workspaces
    }

    /// The folder of scrollback checkpoints classic keeps beside `sessionFile`
    /// (`session-<bundle>-scrollback/`, one `<panel id>.json` per terminal);
    /// nil for a `session-history` archive, whose terminals are older.
    public static func checkpointFolder(for sessionFile: URL) -> URL? {
        let name = sessionFile.lastPathComponent
        guard name.hasPrefix("session-"), name.hasSuffix(".json"), sessionFile.deletingLastPathComponent().lastPathComponent != "session-history"
        else { return nil }
        var stem = String(name.dropLast(".json".count))
        if stem.hasSuffix("-previous") { stem = String(stem.dropLast("-previous".count)) }
        return sessionFile.deletingLastPathComponent().appendingPathComponent("\(stem)-scrollback", isDirectory: true)
    }

    /// ``decodeSnapshot(_:)``, with each terminal's scrollback taken from
    /// classic's checkpoint in `checkpoints` when the snapshot itself carries
    /// no scrollback at all: an 8 s autosave, the last save before classic
    /// crashed, was force quit or the Mac lost power. A quit save's own
    /// scrollback always wins, as in classic's restore.
    public func decodeSnapshot(_ data: Data, checkpoints: URL?) throws -> ClassicSessionSnapshot {
        try Self.validateEncodedJSON(data, maximumBytes: Self.maximumSnapshotBytes)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClassicSessionImportError.notASnapshot
        }
        return try decodeSnapshot(root, checkpoints: checkpoints)
    }

    /// Decodes the snapshot with its windows, groups, and each workspace's
    /// key, color, pin and group. Names are made unique across all windows.
    public func decodeSnapshot(_ data: Data) throws -> ClassicSessionSnapshot {
        try decodeSnapshot(data, checkpoints: nil)
    }

    private func decodeSnapshot(_ root: [String: Any], checkpoints: URL?) throws -> ClassicSessionSnapshot {
        let windows = (root["windows"] as? [[String: Any]]) ?? []
        guard windows.count <= Self.maximumWindows else { throw ClassicSessionImportError.snapshotTooComplex }
        let managers = windows.map { window in
            window["tabManager"] as? [String: Any] ?? window["tab_manager"] as? [String: Any] ?? [:]
        }
        let perWindow = managers.map { ($0["workspaces"] as? [[String: Any]]) ?? [] }
        let workspaces = perWindow.flatMap { $0 }
        guard workspaces.count <= Self.maximumWorkspaces else { throw ClassicSessionImportError.snapshotTooComplex }
        var budget = DecodeBudget()
        try Self.validateJSON(root, budget: &budget)
        for workspace in workspaces { try Self.validate(workspace, budget: &budget) }
        // Classic merges checkpoints only after an unclean exit, whose last
        // save is an autosave: one without any scrollback.
        let saved = Self.carriesScrollback(workspaces)
        var checkpointBytes = 0
        let scrollback: (String) -> String? = { panel in
            let remaining = Self.maximumTotalScrollbackBytes - checkpointBytes
            guard !saved, let checkpoints, remaining > 0,
                  let text = Self.checkpoint(
                      panel,
                      in: checkpoints,
                      maximumBytes: min(Self.maximumScrollbackBytes, remaining)
                  ) else { return nil }
            let bytes = text.utf8.count
            guard bytes <= remaining else { return nil }
            checkpointBytes += bytes
            return text
        }
        var names = Self.names(perWindow.flatMap { $0 }.map(Self.clues))[...]
        let decoded = zip(windows, zip(managers, perWindow)).map { window, pair in
            let (manager, workspaces) = pair
            let mine = names.prefix(workspaces.count)
            names = names.dropFirst(workspaces.count)
            return ClassicSessionWindow(
                id: window["windowId"] as? String ?? window["window_id"] as? String,
                frame: Self.rect(window["frame"]),
                selectedWorkspace: (manager["selectedWorkspaceIndex"] as? NSNumber)?.intValue
                    ?? (manager["selected_workspace_index"] as? NSNumber)?.intValue,
                workspaces: zip(workspaces, mine).map { Self.workspace($0, name: $1, checkpoint: scrollback) },
                groups: ((manager["workspaceGroups"] as? [[String: Any]]) ?? (manager["workspace_groups"] as? [[String: Any]]) ?? [])
                    .compactMap(Self.group))
        }
        return ClassicSessionSnapshot(version: (root["version"] as? NSNumber)?.intValue ?? 1,
                                      createdAt: (root["createdAt"] as? NSNumber)?.doubleValue, windows: decoded)
    }

    private static func rect(_ value: Any?) -> CGRect? {
        guard let value = value as? [String: Any],
              let x = (value["x"] as? NSNumber)?.doubleValue, let y = (value["y"] as? NSNumber)?.doubleValue,
              let width = (value["width"] as? NSNumber)?.doubleValue, let height = (value["height"] as? NSNumber)?.doubleValue,
              width > 0, height > 0 else { return nil }
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private static func group(_ value: [String: Any]) -> ClassicSessionGroup? {
        guard let id = value["id"] as? String, !id.isEmpty else { return nil }
        let color = (value["customColor"] as? String ?? value["custom_color"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let icon = (value["iconSymbol"] as? String ?? value["icon_symbol"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return ClassicSessionGroup(id: id, name: value["name"] as? String ?? "",
                                   collapsed: value["isCollapsed"] as? Bool ?? value["is_collapsed"] as? Bool ?? false,
                                   pinned: value["isPinned"] as? Bool ?? value["is_pinned"] as? Bool ?? false,
                                   color: color, icon: icon)
    }

    /// The workspace's identity across classic saves.
    static func key(_ value: [String: Any], name: String) -> String {
        for field in ["stableId", "stable_id", "workspaceId", "workspace_id"] {
            if let id = value[field] as? String, !id.isEmpty { return id }
        }
        // No id (a very old snapshot): its folder, its name and its panels.
        let panels = ((value["panels"] as? [[String: Any]]) ?? []).compactMap { $0["id"] as? String }
        let parts = [directory(value), name] + panels
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in parts.joined(separator: "\u{1f}").utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x100000001b3
        }
        return "derived:" + String(hash, radix: 16)
    }

    private static func directory(_ value: [String: Any]) -> String {
        (value["currentDirectory"] as? String) ?? (value["current_directory"] as? String) ?? NSHomeDirectory()
    }

    /// Whether any terminal in `workspaces` carries its own scrollback (a quit save).
    private static func carriesScrollback(_ workspaces: [[String: Any]]) -> Bool {
        workspaces.contains { workspace in
            ((workspace["panels"] as? [[String: Any]]) ?? []).contains { panel in
                ((panel["terminal"] as? [String: Any])?["scrollback"] as? String).map { !$0.isEmpty } ?? false
            }
        }
    }

    /// The scrollback classic's checkpoint holds for `panel`
    /// (`<folder>/<PANEL UUID>.json`, `{panelId, scrollback, ...}`); nil
    /// when there is none or it records another panel.
    private static func checkpoint(_ panel: String, in folder: URL, maximumBytes: Int) -> String? {
        let name = panel.uppercased()
        // Panel ids are UUIDs; anything else is not a file name to read.
        guard UUID(uuidString: name) != nil else { return nil }
        // concurrency-allow: called from readSnapshot, which callers run on a detached utility task.
        let loaded: Data?
        do {
            loaded = try readData(
                at: folder.appendingPathComponent("\(name).json"),
                maximumBytes: maximumBytes
            )
        } catch {
            return nil
        }
        guard let data = loaded else { return nil }
        do {
            try validateEncodedJSON(data, maximumBytes: maximumBytes)
        } catch {
            return nil
        }
        guard let record = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              (record["panelId"] as? String)?.uppercased() == name,
              let text = record["scrollback"] as? String, !text.isEmpty else { return nil }
        return text
    }

    private static func workspace(_ value: [String: Any], name: String,
                                  checkpoint: (String) -> String? = { _ in nil }) -> ClassicSessionWorkspace {
        let cwd = Self.directory(value)
        let panels = (value["panels"] as? [[String: Any]]) ?? []
        let panelEntries = panels.compactMap { panel -> (String, ClassicSessionTab)? in
            guard let id = panel["id"] as? String else { return nil }
            return Self.tab(panel, checkpoint: { checkpoint(id) }).map { (id, $0) }
        }
        // Panels nothing here can show (markdown, file preview) stay in classic.
        let leftOutPanels = panels.contains { !["terminal", "browser"].contains($0["type"] as? String ?? "terminal") }
        // A snapshot can name a panel twice; the first wins.
        let panelMap = Dictionary(panelEntries, uniquingKeysWith: { first, _ in first })
        guard let layoutValue = value["layout"] as? [String: Any] else {
            var seen = Set<String>()
            let tabs = panelEntries.filter { seen.insert($0.0).inserted }.map { $0.1 }
            return ClassicSessionWorkspace(name: name, workingDirectory: cwd, layout: .pane(ClassicSessionPane(tabs: tabs)),
                                           remote: Self.remote(value), cloudVM: Self.cloudVM(value), leftOutPanels: leftOutPanels,
                                           key: Self.key(value, name: name), color: Self.color(value),
                                           pinned: value["isPinned"] as? Bool ?? false, groupID: Self.groupID(value))
        }
        let layout = Self.layout(layoutValue, panels: panelMap)
        return ClassicSessionWorkspace(name: name, workingDirectory: cwd, layout: layout,
                                       remote: Self.remote(value), cloudVM: Self.cloudVM(value), leftOutPanels: leftOutPanels,
                                       key: Self.key(value, name: name), color: Self.color(value),
                                       pinned: value["isPinned"] as? Bool ?? false, groupID: Self.groupID(value))
    }

    private static func color(_ value: [String: Any]) -> String? {
        (value["customColor"] as? String ?? value["custom_color"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    private static func groupID(_ value: [String: Any]) -> String? {
        (value["groupId"] as? String ?? value["group_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// A terminal or browser panel as a tab; nil for a panel nothing here can
    /// show (markdown, file preview). Old snapshots name no type.
    private static func tab(_ panel: [String: Any], checkpoint: () -> String? = { nil }) -> ClassicSessionTab? {
        switch panel["type"] as? String ?? "terminal" {
        case "terminal":
            let terminal = panel["terminal"] as? [String: Any]
            let directory = terminal?["workingDirectory"] as? String ?? terminal?["working_directory"] as? String
                ?? panel["directory"] as? String ?? panel["working_directory"] as? String
            return ClassicSessionTab(workingDirectory: directory, title: panel["customTitle"] as? String ?? panel["title"] as? String,
                                     agent: Self.agent(terminal?["agent"] as? [String: Any], directory: directory)
                                        ?? Self.endedAgent(terminal?["resumeBinding"] as? [String: Any], directory: directory),
                                     scrollback: (terminal?["scrollback"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? checkpoint())
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

    /// The longest workspace name cmux-next's daemon takes, in UTF-8 bytes.
    public static let maximumNameBytes = 1024

    /// The user's own title; else a running command or tab title, the
    /// agent it ran, or the folder's name. Names several workspaces share
    /// take each one's branch, and a number only as the last resort.
    static func names(_ clues: [NameClues]) -> [String] {
        // Room left for a branch or a number, so the final name fits the daemon's limit.
        var names = clues.map { fitting($0.custom ?? $0.titles.first ?? $0.agent ?? $0.folder, bytes: maximumNameBytes - 128) }
        let counts = Dictionary(names.map { ($0, 1) }, uniquingKeysWith: +)
        for index in names.indices where counts[names[index], default: 0] > 1 && clues[index].custom == nil {
            if let branch = clues[index].branch, branch != names[index] { names[index] += " · \(branch)" }
        }
        var seen: [String: Int] = [:]
        return names.map { name in
            seen[name, default: 0] += 1
            let count = seen[name, default: 1]
            return fitting(count == 1 ? name : "\(name) \(count)", bytes: maximumNameBytes)
        }
    }

    /// `name` cut at a character so it takes at most `bytes` UTF-8 bytes.
    private static func fitting(_ name: String, bytes: Int) -> String {
        guard name.utf8.count > bytes else { return name }
        var cut = Substring(name)
        while cut.utf8.count > bytes { cut = cut.dropLast() }
        return String(cut)
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
