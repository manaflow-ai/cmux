public import Foundation

/// A parsed, schema-checked `cmux-app.json` (spec section 3, manifest
/// version 1). Decode with `AppManifest.decode(_:)` for the full issue
/// list, or through `Codable` (a `DecodingError` names the first issue's
/// JSON Pointer path). `raw` keeps the whole document for re-encoding.
public nonisolated struct AppManifest: Sendable, Hashable, Identifiable {
    /// `<publisher>/<name>`, stable forever (`cmux/github-prs`, `local/x`).
    public var id: String
    public var name: AppLocalizedText
    public var version: String
    public var description: AppLocalizedText
    public var publisherName: String?
    public var publisherURL: URL?
    public var repository: URL?
    public var homepage: URL?
    public var license: String?
    public var icon: AppIcon?
    public var categories: [String]
    public var keywords: [String]
    /// `engines.cmux`: semver range of the app API.
    public var engine: String
    /// Path of the classic script `main` (absent: declarative-only app).
    public var main: String?
    public var scopes: [AppScopeRequest]
    public var optionalScopes: [AppScopeRequest]
    public var contributes: AppContributions
    public var activation: [String]
    public var files: [String]
    public var raw: AppJSON

    /// The publisher segment of the id (`cmux`, `local`).
    public var publisher: String { String(id.prefix { $0 != "/" }) }
    /// A sideloaded development app (never in the store).
    public var isLocal: Bool { publisher == "local" }
    /// Global id of a contribution: `<app id>#<contribution id>`.
    public func globalID(of contribution: AppContribution) -> String { "\(id)#\(contribution.id)" }

    /// Parses and validates `data`; throws every schema issue at once.
    public static func decode(_ data: Data) throws(AppManifestError) -> AppManifest {
        let json: AppJSON
        do { json = try AppJSON.parse(data) } catch { throw .unreadable(error.localizedDescription) }
        return try decode(json)
    }

    /// Validates a parsed document.
    public static func decode(_ json: AppJSON) throws(AppManifestError) -> AppManifest {
        let issues = AppManifestValidator.validate(json)
        guard issues.isEmpty, case .object(let o) = json else { throw .invalid(issues) }
        return AppManifest(object: o, raw: json)
    }

    private init(object o: [String: AppJSON], raw: AppJSON) {
        self.raw = raw
        id = o["id"]?.stringValue ?? ""
        name = AppLocalizedText(json: o["name"]) ?? AppLocalizedText(id)
        version = o["version"]?.stringValue ?? "0.0.0"
        description = AppLocalizedText(json: o["description"]) ?? AppLocalizedText("")
        publisherName = o["publisher"]?["name"]?.stringValue
        publisherURL = o["publisher"]?["url"]?.stringValue.flatMap(URL.init(string:))
        repository = o["repository"]?.stringValue.flatMap(URL.init(string:))
        homepage = o["homepage"]?.stringValue.flatMap(URL.init(string:))
        license = o["license"]?.stringValue
        icon = AppIcon(json: o["icon"])
        categories = o["categories"]?.arrayValue?.compactMap(\.stringValue) ?? []
        keywords = o["keywords"]?.arrayValue?.compactMap(\.stringValue) ?? []
        engine = o["engines"]?["cmux"]?.stringValue ?? ""
        main = o["main"]?.stringValue
        scopes = AppScopeRequest.list(o["scopes"])
        optionalScopes = AppScopeRequest.list(o["optionalScopes"])
        contributes = AppContributions(json: o["contributes"])
        activation = o["activation"]?.arrayValue?.compactMap(\.stringValue) ?? []
        files = o["files"]?.arrayValue?.compactMap(\.stringValue) ?? []
    }
}

nonisolated extension AppManifest: Codable {
    public init(from decoder: any Decoder) throws {
        let json = try AppJSON(from: decoder)
        do {
            self = try AppManifest.decode(json)
        } catch {
            let first = error.issues.first
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: first.map { "\($0.path): \($0.message) (\($0.code))" } ?? error.description))
        }
    }

    public func encode(to encoder: any Encoder) throws { try raw.encode(to: encoder) }
}
