public import Foundation
import os

/// The one browser source registry (decision BOOKMARKS-IMPORT-EVERY-BROWSER
/// I1): a checked-in JSON catalog that bookmarks, passwords, cookies and
/// history imports all read. A new Chromium fork is a new row, not new code.
public struct BrowserSourceRegistry: Sendable, Codable, Equatable {
    public var schemaVersion: Int
    public var engines: [BrowserFamily: EngineDefaults]
    public var browsers: [BrowserSourceRow] {
        didSet { index = Self.index(browsers) }
    }
    public var nonBrowsers: [NonBrowserApp]
    /// Row position by id (the first row wins; validation reports duplicates).
    private var index: [String: Int]

    private enum CodingKeys: String, CodingKey { case schemaVersion, engines, browsers, nonBrowsers }

    public init(schemaVersion: Int, engines: [BrowserFamily: EngineDefaults], browsers: [BrowserSourceRow], nonBrowsers: [NonBrowserApp] = []) {
        self.schemaVersion = schemaVersion
        self.engines = engines
        self.browsers = browsers
        self.nonBrowsers = nonBrowsers
        index = Self.index(browsers)
    }

    private static func index(_ rows: [BrowserSourceRow]) -> [String: Int] {
        var index: [String: Int] = [:]
        for (position, row) in rows.enumerated() where index[row.id] == nil { index[row.id] = position }
        return index
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        let raw = try container.decode([String: EngineDefaults].self, forKey: .engines)
        var engines: [BrowserFamily: EngineDefaults] = [:]
        for (key, value) in raw {
            guard let family = BrowserFamily(rawValue: key) else {
                throw DecodingError.dataCorruptedError(forKey: .engines, in: container, debugDescription: "unknown engine \(key)")
            }
            engines[family] = value
        }
        self.engines = engines
        let rows = try container.decode([BrowserSourceRow].self, forKey: .browsers)
        browsers = rows
        nonBrowsers = try container.decodeIfPresent([NonBrowserApp].self, forKey: .nonBrowsers) ?? []
        index = Self.index(rows)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(Dictionary(uniqueKeysWithValues: engines.map { ($0.key.rawValue, $0.value) }), forKey: .engines)
        try container.encode(browsers, forKey: .browsers)
        try container.encode(nonBrowsers, forKey: .nonBrowsers)
    }

    /// Decodes a registry document.
    public static func decode(_ data: Data) throws -> BrowserSourceRegistry {
        try JSONDecoder().decode(BrowserSourceRegistry.self, from: data)
    }

    /// The checked-in registry. A missing or broken resource leaves an empty
    /// registry (nothing is detected) and logs once; the validation test
    /// keeps the checked-in file decodable.
    public static let shared: BrowserSourceRegistry = {
        let empty = BrowserSourceRegistry(schemaVersion: 1, engines: [:], browsers: [])
        guard let url = Bundle.module.url(forResource: "browser-sources", withExtension: "json") else {
            Logger(subsystem: "com.cmuxterm.app.next", category: "browser-import").error("browser-sources.json is missing")
            return empty
        }
        do {
            return try decode(Data(contentsOf: url))
        } catch {
            Logger(subsystem: "com.cmuxterm.app.next", category: "browser-import")
                .error("browser-sources.json: \(String(describing: error), privacy: .public)")
            return empty
        }
    }()

    public func row(_ id: String) -> BrowserSourceRow? {
        index[id].map { browsers[$0] }
    }

    /// The row with engine defaults filled in.
    public func resolved(_ row: BrowserSourceRow) -> ResolvedBrowserSource {
        let defaults = engines[row.engine]
        var files = defaults?.files ?? BrowserDataFiles()
        if let own = row.files {
            files.bookmarks = own.bookmarks ?? files.bookmarks
            files.history = own.history ?? files.history
            files.passwords = own.passwords ?? files.passwords
            files.cookies = own.cookies ?? files.cookies
        }
        return ResolvedBrowserSource(row: row, profiles: row.profiles ?? defaults?.profiles ?? .single,
                                     bookmarks: row.bookmarks ?? defaults?.bookmarks ?? .noStore, files: files)
    }

    /// Problems that make the registry unusable; empty when it is valid.
    /// Checked by the registry test, so a bad row never ships.
    public func validationProblems() -> [String] {
        var problems: [String] = []
        if schemaVersion != 1 { problems.append("unknown schemaVersion \(schemaVersion)") }
        for family in [BrowserFamily.chromium, .firefox, .safari, .webkit, .other] where engines[family] == nil {
            problems.append("engine \(family.rawValue) has no defaults")
        }
        var ids = Set<String>(), bundleIDs = Set<String>(), folders = Set<String>()
        for row in browsers {
            let name = row.id
            if row.id.isEmpty || !row.id.allSatisfy({ $0.isLetter || $0.isNumber }) { problems.append("\(name): id must be letters and digits") }
            if !ids.insert(row.id).inserted { problems.append("\(name): duplicate id") }
            if row.name.isEmpty { problems.append("\(name): no name") }
            if row.vendor.isEmpty { problems.append("\(name): no vendor") }
            if row.bundleIDs.isEmpty, row.verified != false || (row.appNames ?? []).isEmpty {
                problems.append("\(name): no bundle id (only unverified rows with app names may have none)")
            }
            for id in row.bundleIDs where !bundleIDs.insert(id).inserted { problems.append("\(name): bundle id \(id) is in two rows") }
            if row.dataDirectories.isEmpty { problems.append("\(name): no data folder") }
            for folder in row.dataDirectories {
                if !folder.hasPrefix("Library/") || folder.contains("..") { problems.append("\(name): data folder \(folder) is not under ~/Library") }
                // Two sources never share a folder (they would list the same profiles twice).
                if !folders.insert(folder).inserted { problems.append("\(name): data folder \(folder) is in two rows") }
            }
            for file in [row.sidebarFile, row.cookieFile].compactMap({ $0 }) where !file.hasPrefix("Library/") || file.contains("..") {
                problems.append("\(name): \(file) is not under ~/Library")
            }
            for kind in row.unsupportedKinds ?? [] where ImportDataKind(rawValue: kind) == nil {
                problems.append("\(name): unknown kind \(kind) in unsupportedKinds")
            }
            if row.evidence.isEmpty { problems.append("\(name): no evidence") }
            for item in row.evidence where !(item.url.hasPrefix("https://") && URL(string: item.url)?.host?.isEmpty == false) || item.note.isEmpty {
                problems.append("\(name): evidence needs an https URL and a note")
            }
            let resolved = resolved(row)
            if let item = row.safeStorage, item.service.trimmingCharacters(in: .whitespaces).isEmpty {
                problems.append("\(name): empty Safe Storage item")
            }
            if row.engine != .chromium, row.safeStorage != nil { problems.append("\(name): only Chromium rows have a Safe Storage item") }
            if resolved.bookmarks == .arcSidebar, row.sidebarFile == nil { problems.append("\(name): arcSidebar needs sidebarFile") }
            if [.chromiumJSON, .firefoxPlaces, .safariPlist].contains(resolved.bookmarks), resolved.files.bookmarks == nil {
                problems.append("\(name): bookmarks format \(resolved.bookmarks.rawValue) needs a bookmarks file")
            }
        }
        for app in nonBrowsers {
            if app.verdict.isEmpty || app.evidence.isEmpty { problems.append("\(app.name): non-browser needs a verdict and evidence") }
            for id in app.bundleIDs where bundleIDs.contains(id) { problems.append("\(app.name): bundle id \(id) is also a browser row") }
        }
        return problems
    }
}

/// A registry row with the engine's defaults applied.
public struct ResolvedBrowserSource: Sendable, Equatable {
    public var row: BrowserSourceRow
    public var profiles: ProfileDiscovery
    public var bookmarks: BookmarksFormat
    public var files: BrowserDataFiles
}
