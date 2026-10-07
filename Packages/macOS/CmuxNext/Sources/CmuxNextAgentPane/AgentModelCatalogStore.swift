public import CmuxNextSettings
public import Foundation

/// The app's copy of the cmux model catalog (decision M2, contract
/// `.cmux-scratch/nx-model-catalog/CONTRACT.md`): `GET <api>/api/models/catalog`, revalidated
/// with its ETag, kept on disk for the next launch and for offline use. A body that is not a
/// schema 1 catalog never replaces the good copy. The page bundles its own snapshot, so a store
/// with no copy answers `catalog: null` and the composer still has models.
///
/// Fetch policy: the first request after launch revalidates (a cheap 304 when nothing changed),
/// then a copy older than ``maximumAge`` does, and `refresh` always does. A failed fetch is not
/// retried for ``retryInterval`` unless `refresh` asks.
public actor AgentModelCatalogStore {
    public typealias Fetch = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    public struct Result: Sendable, Equatable {
        /// The catalog JSON, or nil when the app has no copy yet.
        public var catalog: JSONValue?
        /// `network` (fetched this launch) or `disk` (an earlier launch's copy); nil with no copy.
        public var delivery: String?
        /// A fetch during this call replaced the catalog with a different one (push it to open pages).
        public var changed: Bool
    }

    private struct Meta: Codable {
        var etag: String?
        var fetchedAt: Date
    }

    public static let maximumAge: TimeInterval = 6 * 3600
    public static let retryInterval: TimeInterval = 5 * 60
    static let requestTimeout: TimeInterval = 20

    private let endpoint: URL?
    private let cacheFile: URL
    private let metaFile: URL
    private let fetch: Fetch
    private var now: @Sendable () -> Date

    private var loaded = false
    private var catalog: JSONValue?
    private var meta: Meta?
    private var delivery: String?
    private var fetchedThisLaunch = false
    private var lastFailure: Date?
    private var changedByFetch = false
    private var inFlight: Task<Void, Never>?

    public init(endpoint: URL?, cacheFile: URL,
                fetch: @escaping Fetch = { try await URLSession.shared.data(for: $0) },
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.endpoint = endpoint
        self.cacheFile = cacheFile
        metaFile = cacheFile.deletingPathExtension().appendingPathExtension("meta.json")
        self.fetch = fetch
        self.now = now
    }

    /// The catalog for a page request. `remote` false (cmux.json `agentPane.models.remoteCatalog`)
    /// answers from disk only.
    public func current(refresh: Bool, remote: Bool) async -> Result {
        if !loaded { return Result(catalog: nil, delivery: nil, changed: false) } // red: not implemented
        loadDisk()
        if remote, endpoint != nil, shouldFetch(refresh: refresh) {
            if inFlight == nil {
                inFlight = Task { await self.revalidate() }
            }
            await inFlight?.value
            inFlight = nil
        }
        let changed = changedByFetch
        changedByFetch = false
        return Result(catalog: catalog, delivery: catalog == nil ? nil : delivery, changed: changed)
    }

    func setClockForTests(_ clock: @escaping @Sendable () -> Date) { now = clock }

    private func shouldFetch(refresh: Bool) -> Bool {
        if refresh || !fetchedThisLaunch && lastFailure == nil { return true }
        if let lastFailure, now().timeIntervalSince(lastFailure) < Self.retryInterval { return false }
        guard let meta else { return true }
        return now().timeIntervalSince(meta.fetchedAt) >= Self.maximumAge
    }

    private func revalidate() async {
        guard let endpoint else { return }
        var request = URLRequest(url: endpoint, timeoutInterval: Self.requestTimeout)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if catalog != nil, let etag = meta?.etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        do {
            let (data, response) = try await fetch(request)
            guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            switch http.statusCode {
            case 304 where catalog != nil:
                store(body: nil, etag: http.value(forHTTPHeaderField: "ETag") ?? meta?.etag)
            case 200:
                guard let value = try? JSONValue.parse(data), Self.isCatalog(value) else { throw URLError(.cannotParseResponse) }
                changedByFetch = changedByFetch || value != catalog
                catalog = value
                delivery = "network"
                store(body: data, etag: http.value(forHTTPHeaderField: "ETag"))
            default:
                throw URLError(.badServerResponse)
            }
            fetchedThisLaunch = true
            lastFailure = nil
        } catch {
            lastFailure = now()
        }
    }

    /// A schema 1 catalog: what the page can read (`readModelCatalog` checks the same).
    static func isCatalog(_ value: JSONValue) -> Bool {
        value["schemaVersion"]?.intValue == 1 && value["harnesses"]?.arrayValue != nil
            && value["models"]?.objectValue != nil && value["providers"]?.objectValue != nil
    }

    private func loadDisk() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: cacheFile), let value = try? JSONValue.parse(data), Self.isCatalog(value) else { return }
        catalog = value
        delivery = "disk"
        meta = (try? Data(contentsOf: metaFile)).flatMap { try? JSONDecoder().decode(Meta.self, from: $0) }
    }

    /// Writes the body (when new) and the ETag + fetch time; a failed write only costs the next
    /// launch a full fetch.
    private func store(body: Data?, etag: String?) {
        let next = Meta(etag: etag, fetchedAt: now())
        meta = next
        let directory = cacheFile.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let body { try? body.write(to: cacheFile, options: .atomic) }
        if let encoded = try? JSONEncoder().encode(next) { try? encoded.write(to: metaFile, options: .atomic) }
    }

    /// The page reply and event value: `{catalog, delivery, user}` (CONTRACT section 2).
    public static func reply(catalog: JSONValue?, delivery: String?, user: JSONValue?) -> JSONValue {
        ["catalog": catalog ?? .null, "delivery": delivery.map(JSONValue.string) ?? .null, "user": user ?? .null]
    }

    /// cmux.json `agentPane.models.remoteCatalog`: on unless it is `false`.
    public static func remoteEnabled(_ user: JSONValue?) -> Bool {
        user?["remoteCatalog"]?.boolValue != false
    }

    /// `agentPane.models` in a cmux.json document.
    public static let configPath = ["agentPane", "models"]
}
