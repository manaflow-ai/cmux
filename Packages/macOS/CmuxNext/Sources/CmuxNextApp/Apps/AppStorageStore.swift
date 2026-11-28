import CmuxNextApps
import Foundation

/// `cmux.storage.*` for the DEV prototype engine: one JSON object per app
/// in `<apps dir>/storage/<publisher>__<name>.json`, 5 MiB per app (spec
/// section 8). The Rust app supervisor's SQLite store replaces it.
actor AppStorageStore {
    static let quota = 5 * 1024 * 1024
    private let directory: URL
    private var cache: [String: [String: AppJSON]] = [:]

    init(directory: URL) {
        self.directory = directory
    }

    func get(app: String, key: String) throws -> AppJSON { try values(app)[key] ?? .null }

    func set(app: String, key: String, value: AppJSON) throws -> AppJSON {
        var values = try values(app)
        values[key] = value
        try write(app, values)
        return .null
    }

    func delete(app: String, key: String) throws -> AppJSON {
        var values = try values(app)
        values.removeValue(forKey: key)
        try write(app, values)
        return .null
    }

    func keys(app: String) throws -> AppJSON { .array(try values(app).keys.sorted().map(AppJSON.string)) }

    /// Deletes an app's storage (uninstall).
    func clear(app: String) {
        cache.removeValue(forKey: app)
        try? FileManager.default.removeItem(at: url(app))
    }

    private func url(_ app: String) -> URL {
        directory.appending(path: app.replacingOccurrences(of: "/", with: "__") + ".json")
    }

    private func values(_ app: String) throws -> [String: AppJSON] {
        if let cached = cache[app] { return cached }
        // concurrency-allow: runs on the AppStorageStore actor, never the main thread
        let loaded = (try? Data(contentsOf: url(app))).flatMap { try? AppJSON.parse($0).objectValue } ?? [:]
        cache[app] = loaded
        return loaded
    }

    private func write(_ app: String, _ values: [String: AppJSON]) throws {
        let data = Data(AppJSON.object(values).jsonText.utf8)
        guard data.count <= Self.quota else {
            throw AppOperationError(code: "app.limit", message: "app storage is over 5 MiB", details: ["limit": "storage"])
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: url(app), options: .atomic)
        cache[app] = values
    }
}
