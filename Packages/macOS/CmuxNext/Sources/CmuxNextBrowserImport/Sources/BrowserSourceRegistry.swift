import CmuxNextCompat
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
        try container.encode(Dictionary(engines.map { ($0.key.rawValue, $0.value) }, uniquingKeysWith: { first, _ in first }), forKey: .engines)
        try container.encode(browsers, forKey: .browsers)
        try container.encode(nonBrowsers, forKey: .nonBrowsers)
    }

    /// Decodes a registry document.
    public static func decode(_ data: Data) throws -> BrowserSourceRegistry {
        try JSONDecoder().decode(BrowserSourceRegistry.self, from: data)
    }

    /// The checked-in registry, from ``BrowserSourceRegistryInstall/shared``: loaded on the files lane at
    /// launch (``BrowserSourceRegistryInstall/load(on:)``), so a read finds it in memory.
    public static var shared: BrowserSourceRegistry { BrowserSourceRegistryInstall.shared.registry }

    /// Reads and decodes the checked-in `browser-sources.json`. A missing or broken resource gives an empty
    /// registry (nothing is detected) and logs; the validation test keeps the file decodable. A file read:
    /// call it on a lane (``BrowserSourceRegistryInstall/load(on:)``), never in a static initializer.
    public static func loadBundled() -> BrowserSourceRegistry {
        let empty = BrowserSourceRegistry(schemaVersion: 1, engines: [:], browsers: [])
        #if CMUX_NO_BROWSER_DATA_IMPORT
        // The cx-f58x notary test build ships an empty registry and detects no browser.
        return empty
        #else
        guard let url = Bundle.module.url(forResource: "browser-sources", withExtension: "json") else {
            Logger(subsystem: "com.cmuxterm.app.next", category: "browser-import").error("browser-sources.json is missing")
            return empty
        }
        do {
            return try decode(Data(blockingContentsOf: url))
        } catch {
            Logger(subsystem: "com.cmuxterm.app.next", category: "browser-import")
                .error("browser-sources.json: \(String(describing: error), privacy: .public)")
            return empty
        }
        #endif
    }

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
}

/// A registry row with the engine's defaults applied.
public struct ResolvedBrowserSource: Sendable, Equatable {
    public var row: BrowserSourceRow
    public var profiles: ProfileDiscovery
    public var bookmarks: BookmarksFormat
    public var files: BrowserDataFiles
}
