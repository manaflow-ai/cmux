public import CmuxNextBrowserImport
import CmuxNextCompat
public import Foundation

/// What Classic's file metadata and NEXT's migration ledger establish before consent.
public nonisolated enum ClassicImportAvailability: String, Sendable {
    case unavailable, available, alreadyImported
}

/// Finds what this Mac has that cmux can bring over, cheaply and without
/// asking: folder listings and file existence for browsers and agents, one
/// small property list for iTerm2. It never opens a browser's databases,
/// never touches the Keychain and never raises a privacy prompt (Safari's
/// folder is probed with one `open(2)`, which macOS denies without asking).
/// Call it off the main thread. What the file facts become (the order, which folders are profiles, what each
/// holds, which findings show) is Rust's (`cmux-import-suggest`'s `scan`); this reads the files.
public nonisolated struct ImportScanner: Sendable {
    public var home: URL
    /// Where browsers' data folders are (a fixture home in tests).
    public var environment: ImportEnvironment
    /// `CLAUDE_CONFIG_DIR`, `CODEX_HOME` and `XDG_CONFIG_HOME` when set.
    public var variables: [String: String]
    /// Browser profiles imported before (`<browser>/<profile folder>`, `ImportSourceRecord.sourceKey`): left out.
    public var importedProfiles: Set<String>
    /// The daemon's metadata-only probe for Classic.
    public var classicAvailability: ClassicImportAvailability
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
                importedProfiles: Set<String> = [], classicAvailability: ClassicImportAvailability = .unavailable,
                probe: @escaping @Sendable (URL) -> FileAccess = FileAccess.probe,
                shouldStop: @escaping @Sendable () -> Bool = { false }) {
        self.home = home
        self.environment = environment
        self.variables = variables
        self.importedProfiles = importedProfiles
        self.classicAvailability = classicAvailability
        self.probe = probe
        self.shouldStop = shouldStop
    }

    /// Every source found, browsers first in the order people most often come from.
    public func scan() -> [ImportFinding] {
        var findings = browsers()
        let others: [() -> ImportFinding?] = [claudeCode, codex, classic, conductor, iterm2, ghostty]
        for source in others {
            if shouldStop() { break }
            if let found = source() { findings.append(found) }
        }
        return findings
    }

    // MARK: Browsers

    /// The browsers people most often come from lead; the rest keep registry order (Rust's `scan::LEADING`).
    public static let leading: [ImportBrowser] = [.chrome, .arc, .safari, .zen, .firefox, .brave, .edge, .dia]

    func browsers() -> [ImportFinding] {
        let candidates = ImportBrowser.allCases.filter { browser in
            browser.kind == .browser && !browser.refusesSessionData && [.chromium, .firefox, .safari].contains(browser.family)
        }
        let order = ImportSuggestRules.call("scan_browser_order", ["candidates": candidates.map(\.rawValue)], as: [String].self) ?? []
        let byRaw = Dictionary(candidates.map { ($0.rawValue, $0) }, uniquingKeysWith: { first, _ in first })
        var seenFolders = Set<String>()
        return order.compactMap { byRaw[$0] }.compactMap { browser in
            guard !shouldStop() else { return nil }
            // Another app's container: even a look there can ask the person for "data from other
            // apps", so a registry folder in one is never checked (Safari's is its own grant, except in a
            // `cmux app try` copy, a new identity each try: ``OtherAppContainers``).
            let folders = (browser.dataDirectories.isEmpty ? [browser.dataDirectory] : browser.dataDirectories)
                .map { environment.homeDirectory.appending(path: $0, directoryHint: .isDirectory) }
                .filter { (browser.family == .safari && OtherAppContainers.mayRead) || !Self.isContainer($0) }
            guard let directory = folders.first(where: exists) ?? folders.first else { return nil }
            // Two registry rows on one folder (Zen and Zen Twilight) count once.
            guard seenFolders.insert(directory.standardizedFileURL.path).inserted else { return nil }
            return finding(for: browser, in: directory)
        }
    }

    func finding(for browser: ImportBrowser, in directory: URL) -> ImportFinding? {
        switch browser.family {
        case .safari:
            let history = probe(directory.appending(path: "History.db"))
            let historyAccess = switch history {
            case .missing: "missing"
            case .denied: "denied"
            case .readable: "readable"
            }
            // Bookmarks.plist is only opened when History.db reads. The cookie file is in Safari's container:
            // opening it to look would ask the person for "data from other apps", so only the registry says.
            let fields: [String: any Encodable] = [
                "browser": browser.rawValue, "name": browser.displayName, "history": historyAccess,
                "bookmarksReadable": history == .readable && probe(directory.appending(path: "Bookmarks.plist")) == .readable,
                "hasCookieFile": browser.safariCookieFile != nil, "imported": importedProfiles.sorted(),
            ]
            return found(ImportSuggestRules.call("scan_safari", fields, as: ImportFinding?.self) ?? nil, browser)
        case .chromium:
            return profilesFinding(browser: browser, profiles: chromiumProfiles(browser, in: directory))
        case .firefox:
            return profilesFinding(browser: browser, profiles: firefoxProfiles(in: directory))
        case .webkit, .other:
            return nil
        }
    }

    private func profilesFinding(browser: ImportBrowser, profiles: [ImportFinding.Profile]) -> ImportFinding? {
        let fields: [String: any Encodable] = ["browser": browser.rawValue, "name": browser.displayName, "profiles": profiles,
                                               "imported": importedProfiles.sorted()]
        return found(ImportSuggestRules.call("scan_profiles_finding", fields, as: ImportFinding?.self) ?? nil, browser)
    }

    /// A browser finding back from Rust, with its registry row (the raw id alone codes it).
    private func found(_ finding: ImportFinding?, _ browser: ImportBrowser) -> ImportFinding? {
        guard var finding else { return nil }
        finding.browser = browser
        return finding
    }

    /// `Default` and `Profile N` folders (the data folder itself for Opera's layout), by name.
    func chromiumProfiles(_ browser: ImportBrowser, in directory: URL) -> [ImportFinding.Profile] {
        let names = browser.profileIsDataDirectory ? [""]
            : ImportSuggestRules.call("scan_chromium_profiles", ["listing": listing(directory)], as: [String].self) ?? []
        let format = browser.bookmarksFormat
        // Arc keeps its pinned tabs and folders in one sidebar file beside the profiles.
        let sidebar = format == .arcSidebar && (browser.row?.sidebarFile.map { exists(environment.file($0)) } ?? false)
        return names.map { name in
            let folder = name.isEmpty ? directory : directory.appending(path: name, directoryHint: .isDirectory)
            let facts: [String: any Encodable] = [
                "history": exists(folder.appending(path: browser.source?.files.history ?? "History")),
                "bookmarksJson": format == .chromiumJSON && exists(folder.appending(path: browser.source?.files.bookmarks ?? "Bookmarks")),
                "arcSidebar": sidebar,
                "cookies": exists(folder.appending(path: "Network/Cookies")) || exists(folder.appending(path: "Cookies")),
                "safeStorage": browser.safeStorageService != nil,
            ]
            let kinds = ImportSuggestRules.call("scan_chromium_kinds", facts, as: [ImportDataKind].self) ?? []
            return ImportFinding.Profile(directoryName: name, kinds: kinds)
        }
    }

    /// Folders under `Profiles/` that hold a places or cookies database.
    func firefoxProfiles(in directory: URL) -> [ImportFinding.Profile] {
        let names = ImportSuggestRules.call("scan_firefox_profiles", ["listing": listing(directory.appending(path: "Profiles", directoryHint: .isDirectory))],
                                            as: [String].self) ?? []
        return names.map { name in
            let folder = directory.appending(path: name, directoryHint: .isDirectory)
            let facts = ["places": exists(folder.appending(path: "places.sqlite")), "cookies": exists(folder.appending(path: "cookies.sqlite"))]
            return ImportFinding.Profile(directoryName: name, kinds: ImportSuggestRules.call("scan_firefox_kinds", facts, as: [ImportDataKind].self) ?? [])
        }
    }

    // MARK: Agents

    func folder(_ variable: String, default relative: String) -> URL {
        variables[variable].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
            ?? home.appending(path: relative, directoryHint: .isDirectory)
    }

    /// The finding Rust makes of one source's facts (`scan_extras` with only that source's fields).
    private func extra(_ fields: [String: any Encodable]) -> ImportFinding? {
        ImportSuggestRules.call("scan_extras", fields, as: [ImportFinding].self)?.first
    }

    /// The `.jsonl` names in one folder.
    private func sessionFiles(_ folder: URL) -> Int {
        ImportSuggestRules.call("scan_sessions", ["listing": listing(folder)], as: Int.self) ?? 0
    }

    /// Claude Code: one `<session>.jsonl` per session in `projects/<project>/`.
    func claudeCode() -> ImportFinding? {
        let projects = folder("CLAUDE_CONFIG_DIR", default: ".claude").appending(path: "projects", directoryHint: .isDirectory)
        var sessions = 0
        for project in listing(projects) where sessions < Self.listingLimit {
            sessions += sessionFiles(projects.appending(path: project, directoryHint: .isDirectory))
        }
        return extra(["claudeSessions": sessions])
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
                    threads += sessionFiles(monthFolder.appending(path: day, directoryHint: .isDirectory))
                }
            }
        }
        return extra(["codexThreads": threads])
    }

    // MARK: Terminals and cmux Classic

    func classic() -> ImportFinding? {
        extra(["classic": classicAvailability.rawValue])
    }

    /// Conductor's workspaces, one folder each under `~/conductor/workspaces/<repo>`, when its
    /// database or that folder is here. Folder listings only, and only folders count (a file left
    /// there is no workspace): what each one becomes is the import's dry run
    /// (`conductor_import.plan`), read when the person presses Import.
    func conductor() -> ImportFinding? {
        let database = home.appending(path: "Library/Application Support/com.conductor.app/conductor.db")
        let root = home.appending(path: "conductor/workspaces", directoryHint: .isDirectory)
        let workspaces = subfolders(root).reduce(0) { total, repo in
            total + subfolders(root.appending(path: repo, directoryHint: .isDirectory)).count
        }
        return extra(["conductorWorkspaces": workspaces, "conductorDatabaseBytes": size(database)])
    }

    /// Ghostty's config: cmux terminals read it as it is, so it is listed as already in use.
    func ghostty() -> ImportFinding? {
        let config = folder("XDG_CONFIG_HOME", default: ".config").appending(path: "ghostty", directoryHint: .isDirectory)
        let native = home.appending(path: "Library/Application Support/com.mitchellh.ghostty", directoryHint: .isDirectory)
        let files = [config, native].flatMap { [$0.appending(path: "config.ghostty"), $0.appending(path: "config")] }
        return extra(["ghosttyConfigBytes": files.map(size)])
    }

    /// iTerm2's profiles (`New Bookmarks` in its preferences), by name.
    func iterm2() -> ImportFinding? {
        let file = home.appending(path: "Library/Preferences/com.googlecode.iterm2.plist")
        let bytes = size(file)
        guard bytes > 0, bytes <= Self.maximumPreferencesBytes, let data = try? Data(contentsOf: file),
              let names = ITermProfiles(data: data)?.profiles.map(\.name) else { return nil }
        return extra(["iterm2Profiles": names])
    }

    // MARK: File system

    /// A folder's entry names, at most `listingLimit` (hidden ones left out); none when it is missing.
    func listing(_ folder: URL) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return Array(names.lazy.filter { !$0.hasPrefix(".") }.prefix(Self.listingLimit))
    }

    /// ``listing(_:)``'s folders only, from the one directory read (the type comes with each entry).
    func subfolders(_ folder: URL) -> [String] {
        let entries = (try? FileManager.checked.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        return Array(entries.lazy.filter { entry in
            !entry.lastPathComponent.hasPrefix(".") && (try? entry.blockingResourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        }.map(\.lastPathComponent).prefix(Self.listingLimit))
    }

    /// Inside `~/Library/Containers` or `~/Library/Group Containers`, where macOS guards each app's data.
    static func isContainer(_ url: URL) -> Bool {
        ImportSuggestRules.call("scan_is_container", ["path": url.standardizedFileURL.path], as: Bool.self) ?? true
    }

    func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    func size(_ url: URL) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.intValue ?? 0
    }
}
