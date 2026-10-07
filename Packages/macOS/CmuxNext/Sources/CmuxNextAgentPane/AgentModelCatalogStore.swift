public import CmuxNextSettings
public import Foundation

/// Where the app reads the cmux model catalog: acpmux, which fetches it for every client
/// (MODEL-CATALOG-CURATED-PROXY). `get` is `catalog.get`, `refresh` is `catalog.refresh`.
public protocol AgentModelCatalogSource: Sendable {
    func get() async throws -> JSONValue
    func refresh() async throws -> JSONValue
}

/// The app's view of the cmux model catalog (decision M2) as a thin acpmux client: acpmux owns
/// the fetch, the last good copy and the bundled fallback, so the app never fetches over HTTP.
/// A page's `models.catalog` reads `catalog.get`; `refresh` asks `catalog.refresh` first. When
/// acpmux cannot answer, the last catalog it gave stands in, else `catalog: null` and the page
/// keeps its own bundled snapshot.
public actor AgentModelCatalogStore {
    public struct Result: Sendable, Equatable {
        /// The catalog JSON, or nil when acpmux has given none yet.
        public var catalog: JSONValue?
        /// `network` (acpmux fetched it) or `disk` (acpmux's stored or bundled copy); nil with no copy.
        public var delivery: String?
        /// This call saw a catalog different from the one before (push it to open pages).
        public var changed: Bool
    }

    private let source: (any AgentModelCatalogSource)?
    private var catalog: JSONValue?
    private var delivery: String?

    public init(source: (any AgentModelCatalogSource)?) {
        self.source = source
    }

    /// The catalog for a page request. `remote` false (cmux.json `agentPane.models.remoteCatalog`)
    /// never asks acpmux to fetch; it still reads acpmux's copy.
    public func current(refresh: Bool, remote: Bool) async -> Result {
        guard let source else { return Result(catalog: nil, delivery: nil, changed: false) }
        if refresh, remote { _ = try? await source.refresh() }
        let previous = catalog
        if let reply = try? await source.get(), let next = reply["catalog"], Self.isCatalog(next) {
            catalog = next
            delivery = Self.delivery(reply["delivery"]?.stringValue)
        }
        return Result(catalog: catalog, delivery: catalog == nil ? nil : delivery, changed: catalog != nil && catalog != previous)
    }

    /// acpmux's `delivery` as the page's: `fetched` is `network`, `stored` and `bundled` are `disk`.
    static func delivery(_ acpmux: String?) -> String? {
        switch acpmux {
        case "fetched": "network"
        case "stored", "bundled": "disk"
        default: nil
        }
    }

    /// A schema 1 catalog: what the page can read (`readModelCatalog` checks the same).
    static func isCatalog(_ value: JSONValue) -> Bool {
        value["schemaVersion"]?.intValue == 1 && value["harnesses"]?.arrayValue != nil
            && value["models"]?.objectValue != nil && value["providers"]?.objectValue != nil
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

/// ``AgentModelCatalogSource`` over the acpmux unix socket.
public nonisolated struct AcpmuxModelCatalogSource: AgentModelCatalogSource {
    public let socketPath: String
    public init(socketPath: String) { self.socketPath = socketPath }

    public func get() async throws -> JSONValue {
        try await call("catalog.get", deadline: .seconds(2))
    }

    /// A fetch: allow for a slow network (acpmux's own timeout is 30 s).
    public func refresh() async throws -> JSONValue {
        try await call("catalog.refresh", deadline: .seconds(35))
    }

    /// One element per acpmux `catalog.changed`, until the daemon closes the connection.
    public func changes() -> AsyncThrowingStream<Void, any Error> {
        AcpmuxCatalogWatcher.changes(socketPath: socketPath)
    }

    private func call(_ method: String, deadline: Duration) async throws -> JSONValue {
        let box = try await AcpmuxStatusClient.request(socketPath: socketPath, method: method, deadline: deadline)
        return JSONValue(foundation: box.value) ?? .null
    }
}
