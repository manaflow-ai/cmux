public import CmuxNextBrowserImport
public import Foundation

/// Finds what this Mac has that cmux can bring over, cheaply and without
/// asking: folder listings and file existence for browsers and agents, one
/// small property list for iTerm2. It never opens a browser's databases,
/// never touches the Keychain and never raises a privacy prompt (Safari's
/// folder is probed with one `open(2)`, which macOS denies without asking).
/// Call it off the main thread.
public nonisolated struct ImportScanner: Sendable {
    public var home: URL
    /// Where browsers' data folders are (a fixture home in tests).
    public var environment: ImportEnvironment
    /// `CLAUDE_CONFIG_DIR`, `CODEX_HOME` and `XDG_CONFIG_HOME` when set.
    public var variables: [String: String]
    /// Browser profiles imported before (`<browser>/<profile folder>`, `ImportSourceRecord.sourceKey`): left out.
    public var importedProfiles: Set<String>
    /// cmux Classic's saved workspaces on this Mac that are not here yet: nil when Classic has no
    /// saved session, 0 when all of it already came over (Settings › Import still offers it again).
    public var classicWorkspaces: @Sendable () -> Int?
    /// Opens a file to learn whether it can be read (Safari's privacy-protected folder).
    public var probe: @Sendable (URL) -> FileAccess
    /// Asked before each browser and each other source: true ends the scan there, with what it found
    /// so far (`browser.import.enabled` turned off while it ran).
    public var shouldStop: @Sendable () -> Bool

    /// The most entries one folder listing counts, so a huge session folder costs a bounded scan.
    public static let listingLimit = 20_000
    /// The largest iTerm2 preferences file read.
    public static let maximumPreferencesBytes = 16 * 1024 * 1024

    public init(home: URL, environment: ImportEnvironment, variables: [String: String] = [:],
                importedProfiles: Set<String> = [], classicWorkspaces: @escaping @Sendable () -> Int? = { nil },
                probe: @escaping @Sendable (URL) -> FileAccess = FileAccess.probe,
                shouldStop: @escaping @Sendable () -> Bool = { false }) {
        self.home = home
        self.environment = environment
        self.variables = variables
        self.importedProfiles = importedProfiles
        self.classicWorkspaces = classicWorkspaces
        self.probe = probe
        self.shouldStop = shouldStop
    }

    /// Every source found, browsers first in the order people most often come from.
    public func scan() -> [ImportFinding] {
        var findings = browsers()
        let others: [() -> ImportFinding?] = [claudeCode, codex, classic, iterm2, ghostty]
        for source in others {
            if shouldStop() { break }
            if let found = source() { findings.append(found) }
        }
        return findings
    }

    // MARK: Browsers

    /// The browsers people most often come from lead; the rest keep registry order.
    public static let leading: [ImportBrowser] = [.chrome, .arc, .safari, .zen, .firefox, .brave, .edge, .dia]

    func browsers() -> [ImportFinding] {
        let candidates = ImportBrowser.allCases.filter { browser in
            browser.kind == .browser && !browser.refusesSessionData && [.chromium, .firefox, .safari].contains(browser.family)
        }
        let rank = { (browser: ImportBrowser) in Self.leading.firstIndex(of: browser) ?? Self.leading.count }
        var seenFolders = Set<String>()
        return candidates.enumerated().sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }.compactMap { _, browser in
            guard !shouldStop() else { return nil }
            // Another app's container: even a look there can ask the person for "data from other
            // apps", so a registry folder in one is never checked (Safari's is its own grant).
            let folders = (browser.dataDirectories.isEmpty ? [browser.dataDirectory] : browser.dataDirectories)
                .map { environment.homeDirectory.appending(path: $0, directoryHint: .isDirectory) }
                .filter { browser.family == .safari || !Self.isContainer($0) }
            guard let directory = folders.first(where: exists) ?? folders.first else { return nil }
            // Two registry rows on one folder (Zen and Zen Twilight) count once.
            guard seenFolders.insert(directory.standardizedFileURL.path).inserted else { return nil }
            return finding(for: browser, in: directory)
        }
    }

    func finding(for browser: ImportBrowser, in directory: URL) -> ImportFinding? {
        let id = "browser.\(browser.rawValue)"
        switch browser.family {
        case .safari:
            let history = probe(directory.appending(path: "History.db"))
            switch history {
            case .missing: return nil
            case .denied:
                return ImportFinding(id: id, kind: .browser, browser: browser, name: browser.displayName,
                                     profiles: [.init(directoryName: "Safari", kinds: [.history, .bookmarks])], access: .needsFullDiskAccess)
            case .readable:
                guard !importedProfiles.contains("\(browser.rawValue)/Safari") else { return nil }
                var kinds: [ImportDataKind] = [.history]
                if probe(directory.appending(path: "Bookmarks.plist")) == .readable { kinds.append(.bookmarks) }
                // The cookie file is in Safari's container: opening it to look would ask the person
                // for "data from other apps". With Full Disk Access (History.db is readable) it reads.
                if browser.safariCookieFile != nil { kinds.append(.cookies) }
                return ImportFinding(id: id, kind: .browser, browser: browser, name: browser.displayName,
                                     profiles: [.init(directoryName: "Safari", kinds: kinds)])
            }
        case .chromium:
            return profilesFinding(id: id, browser: browser, profiles: chromiumProfiles(browser, in: directory))
        case .firefox:
            return profilesFinding(id: id, browser: browser, profiles: firefoxProfiles(in: directory))
        case .webkit, .other:
            return nil
        }
    }

    private func profilesFinding(id: String, browser: ImportBrowser, profiles: [ImportFinding.Profile]) -> ImportFinding? {
        let fresh = profiles.filter { !$0.kinds.isEmpty && !importedProfiles.contains("\(browser.rawValue)/\($0.directoryName)") }
        guard !fresh.isEmpty else { return nil }
        return ImportFinding(id: id, kind: .browser, browser: browser, name: browser.displayName, profiles: fresh)
    }

    /// `Default` and `Profile N` folders (the data folder itself for Opera's layout), by name.
    func chromiumProfiles(_ browser: ImportBrowser, in directory: URL) -> [ImportFinding.Profile] {
        let names = browser.profileIsDataDirectory ? [""] : listing(directory).filter { name in
            name == "Default" || (name.hasPrefix("Profile ") && Int(name.dropFirst("Profile ".count)) != nil)
        }.sorted { Self.profileOrder($0) < Self.profileOrder($1) }
        let format = browser.bookmarksFormat
        // Arc keeps its pinned tabs and folders in one sidebar file beside the profiles.
        let sidebar = format == .arcSidebar && (browser.row?.sidebarFile.map { exists(environment.file($0)) } ?? false)
        return names.map { name in
            let folder = name.isEmpty ? directory : directory.appending(path: name, directoryHint: .isDirectory)
            var kinds: [ImportDataKind] = []
            if exists(folder.appending(path: browser.source?.files.history ?? "History")) { kinds.append(.history) }
            if sidebar || (format == .chromiumJSON && exists(folder.appending(path: browser.source?.files.bookmarks ?? "Bookmarks"))) {
                kinds.append(.bookmarks)
            }
            // Without a known Keychain item the cookies cannot be read.
            if browser.safeStorageService != nil, exists(folder.appending(path: "Network/Cookies")) || exists(folder.appending(path: "Cookies")) {
                kinds.append(.cookies)
            }
            return ImportFinding.Profile(directoryName: name, kinds: kinds)
        }
    }

    /// `Default` first, then `Profile 1`, `Profile 2`, ... by number.
    static func profileOrder(_ name: String) -> Int {
        name == "Default" ? -1 : Int(name.dropFirst("Profile ".count)) ?? Int.max
    }

    /// Folders under `Profiles/` that hold a places or cookies database.
    func firefoxProfiles(in directory: URL) -> [ImportFinding.Profile] {
        let profiles = directory.appending(path: "Profiles", directoryHint: .isDirectory)
        return listing(profiles).sorted().map { name in
            let folder = profiles.appending(path: name, directoryHint: .isDirectory)
            var kinds: [ImportDataKind] = []
            if exists(folder.appending(path: "places.sqlite")) { kinds += [.history, .bookmarks] }
            if exists(folder.appending(path: "cookies.sqlite")) { kinds.append(.cookies) }
            return ImportFinding.Profile(directoryName: "Profiles/\(name)", kinds: kinds)
        }
    }

    // MARK: Agents

    func folder(_ variable: String, default relative: String) -> URL {
        variables[variable].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
            ?? home.appending(path: relative, directoryHint: .isDirectory)
    }

    /// Claude Code: one `<session>.jsonl` per session in `projects/<project>/`.
    func claudeCode() -> ImportFinding? {
        let projects = folder("CLAUDE_CONFIG_DIR", default: ".claude").appending(path: "projects", directoryHint: .isDirectory)
        var sessions = 0
        for project in listing(projects) where sessions < Self.listingLimit {
            sessions += listing(projects.appending(path: project, directoryHint: .isDirectory)).filter { $0.hasSuffix(".jsonl") }.count
        }
        return sessions > 0 ? ImportFinding(id: "agents.claudeCode", kind: .claudeCode, name: "Claude Code", count: sessions) : nil
    }

    /// Codex: one `rollout-*.jsonl` per thread in `sessions/YYYY/MM/DD/`.
    func codex() -> ImportFinding? {
        let sessions = folder("CODEX_HOME", default: ".codex").appending(path: "sessions", directoryHint: .isDirectory)
        var threads = 0
        for year in listing(sessions) where threads < Self.listingLimit {
            let yearFolder = sessions.appending(path: year, directoryHint: .isDirectory)
            for month in listing(yearFolder) {
                let monthFolder = yearFolder.appending(path: month, directoryHint: .isDirectory)
                for day in listing(monthFolder) {
                    threads += listing(monthFolder.appending(path: day, directoryHint: .isDirectory)).filter { $0.hasSuffix(".jsonl") }.count
                }
            }
        }
        return threads > 0 ? ImportFinding(id: "agents.codex", kind: .codex, name: "Codex", count: threads) : nil
    }

    // MARK: Terminals and cmux Classic

    func classic() -> ImportFinding? {
        guard let workspaces = classicWorkspaces() else { return nil }
        return ImportFinding(id: "cmux.classic", kind: .cmuxClassic, name: "cmux Classic", count: workspaces)
    }

    /// Ghostty's config: cmux terminals read it as it is, so it is listed as already in use.
    func ghostty() -> ImportFinding? {
        let config = folder("XDG_CONFIG_HOME", default: ".config").appending(path: "ghostty", directoryHint: .isDirectory)
        let native = home.appending(path: "Library/Application Support/com.mitchellh.ghostty", directoryHint: .isDirectory)
        let files = [config, native].flatMap { [$0.appending(path: "config.ghostty"), $0.appending(path: "config")] }
        guard files.contains(where: { size($0) > 0 }) else { return nil }
        return ImportFinding(id: "terminal.ghostty", kind: .ghostty, name: "Ghostty", access: .inUse)
    }

    /// iTerm2's profiles (`New Bookmarks` in its preferences), by name.
    func iterm2() -> ImportFinding? {
        let file = home.appending(path: "Library/Preferences/com.googlecode.iterm2.plist")
        let bytes = size(file)
        guard bytes > 0, bytes <= Self.maximumPreferencesBytes, let data = try? Data(contentsOf: file),
              let names = ITermProfiles(data: data)?.profiles.map(\.name), !names.isEmpty else { return nil }
        return ImportFinding(id: "terminal.iterm2", kind: .iterm2, name: "iTerm2",
                             profiles: names.map { .init(directoryName: $0, kinds: []) }, count: names.count)
    }

    // MARK: File system

    /// A folder's entry names (hidden ones left out), at most `listingLimit`; none when it is missing.
    func listing(_ folder: URL) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return Array(names.lazy.filter { !$0.hasPrefix(".") }.prefix(Self.listingLimit))
    }

    /// Inside `~/Library/Containers` or `~/Library/Group Containers`, where macOS guards each app's data.
    static func isContainer(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        return path.contains("/Library/Containers/") || path.contains("/Library/Group Containers/")
    }

    func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    func size(_ url: URL) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.intValue ?? 0
    }
}
