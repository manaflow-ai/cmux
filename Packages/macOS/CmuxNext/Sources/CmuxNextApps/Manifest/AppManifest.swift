public import Foundation

/// The parts of a `cmux-app.json` the UI renders: name, description, icon,
/// publisher, categories, scopes with their reasons, and the interfaces it
/// implements with their titles. The app supervisor in the daemon validates
/// manifests (the Rust `cmux-app-manifest` crate); the client only reads
/// the fields it shows and ignores everything else, so a newer manifest
/// still renders. Version 2 (`implements`) and version 1 (`contributes`)
/// both decode.
public nonisolated struct AppManifest: Sendable, Hashable, Identifiable {
    /// `<publisher>/<name>`, stable forever (`cmux/github-prs`, `local/x`).
    public var id: String
    public var manifestVersion: Int
    public var name: AppLocalizedText
    public var version: String
    public var description: AppLocalizedText
    public var publisherName: String?
    public var repository: URL?
    public var icon: AppIcon?
    public var categories: [String]
    public var keywords: [String]
    public var scopes: [AppScopeRequest]
    public var optionalScopes: [AppScopeRequest]
    public var implementations: [AppImplementation]
    /// The whole document, as the supervisor sent it.
    public var raw: AppJSON

    /// The publisher segment of the id (`cmux`, `local`).
    public var publisher: String { String(id.prefix { $0 != "/" }) }
    /// A sideloaded development app (never in the store).
    public var isLocal: Bool { publisher == "local" }
    /// Global id of an implementation: `<app id>#<implementation id>`.
    public func globalID(of implementation: AppImplementation) -> String { "\(id)#\(implementation.id)" }
    public var sections: [AppImplementation] { implementations.filter(\.isSection) }

    /// Reads a manifest object; nil when it has no id.
    public init?(json: AppJSON) {
        guard case .object(let o) = json, let id = o["id"]?.stringValue, !id.isEmpty else { return nil }
        self.id = id
        raw = json
        manifestVersion = o["manifestVersion"]?.numberValue.map { Int($0) } ?? 1
        name = AppLocalizedText(json: o["name"]) ?? AppLocalizedText(id)
        version = o["version"]?.stringValue ?? "0.0.0"
        description = AppLocalizedText(json: o["description"]) ?? AppLocalizedText("")
        publisherName = o["publisher"]?["name"]?.stringValue
        repository = o["repository"]?.stringValue.flatMap(URL.init(string:))
        icon = AppIcon(json: o["icon"])
        categories = o["categories"]?.arrayValue?.compactMap(\.stringValue) ?? []
        keywords = o["keywords"]?.arrayValue?.compactMap(\.stringValue) ?? []
        scopes = AppScopeRequest.list(o["scopes"])
        optionalScopes = AppScopeRequest.list(o["optionalScopes"])
        implementations = Self.implementations(o)
    }

    /// Parses UTF-8 JSON; nil when it is not a manifest object.
    public static func decode(_ data: Data) -> AppManifest? {
        (try? AppJSON.parse(data)).flatMap(AppManifest.init(json:))
    }

    /// Version 2 `implements` in interface order; version 1 `contributes`
    /// sections, status items, pane kinds and palette scopes in that order.
    private static func implementations(_ o: [String: AppJSON]) -> [AppImplementation] {
        if let implements = o["implements"]?.objectValue {
            return implements.sorted { $0.key < $1.key }.map { interface, entry in
                AppImplementation(interface: interface, title: AppLocalizedText(json: entry["title"]), symbol: entry["symbol"]?.stringValue)
            }
        }
        let contributes = o["contributes"]?.objectValue ?? [:]
        let kinds: [(String, String)] = [
            ("sidebarSections", AppImplementation.section), ("statusItems", AppImplementation.status),
            ("paneKinds", AppImplementation.pane), ("paletteScopes", AppImplementation.paletteScope),
        ]
        return kinds.flatMap { key, interface in
            (contributes[key]?.arrayValue ?? []).compactMap(\.objectValue).compactMap { entry -> AppImplementation? in
                guard let id = entry["id"]?.stringValue else { return nil }
                return AppImplementation(interface: interface, id: id, title: AppLocalizedText(json: entry["title"]),
                                         symbol: entry["symbol"]?.stringValue)
            }
        }
    }
}
