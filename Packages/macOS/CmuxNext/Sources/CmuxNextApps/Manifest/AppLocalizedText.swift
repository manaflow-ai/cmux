public import Foundation

/// A manifest string: one value, or values by language code with a
/// required `en` (spec section 3, `"name": {"en": "...", "ja": "..."}`).
public nonisolated struct AppLocalizedText: Sendable, Hashable, Codable {
    public var values: [String: String]

    public init(_ english: String) { values = ["en": english] }
    public init(values: [String: String]) { self.values = values }

    init?(json: AppJSON?) {
        switch json {
        case .string(let text)?: values = ["en": text]
        case .object(let object)?: values = object.compactMapValues(\.stringValue)
        default: return nil
        }
    }

    public var english: String { values["en"] ?? values.values.sorted().first ?? "" }

    /// The value for the first preferred language that has one (`ja`,
    /// `pt-BR` falls back to `pt`), else English.
    public func resolved(preferredLanguages: [String] = Locale.preferredLanguages) -> String {
        for language in preferredLanguages {
            if let value = values[language] { return value }
            let base = String(language.prefix { $0 != "-" })
            if let value = values[base] { return value }
        }
        return english
    }

    public init(from decoder: any Decoder) throws {
        let json = try AppJSON(from: decoder)
        guard let text = AppLocalizedText(json: json) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "expected localized text"))
        }
        self = text
    }

    public func encode(to encoder: any Encoder) throws {
        if values.count == 1, let english = values["en"] { try english.encode(to: encoder) } else { try values.encode(to: encoder) }
    }
}

/// The app's icon: a bundle file (SVG or PNG) or an SF Symbol.
public nonisolated enum AppIcon: Sendable, Hashable {
    case file(String)
    case symbol(String)

    init?(json: AppJSON?) {
        switch json {
        case .string(let path)?: self = .file(path)
        case .object(let object)?: guard let name = object["symbol"]?.stringValue else { return nil }; self = .symbol(name)
        default: return nil
        }
    }
}

/// A requested scope and the reason shown at consent.
public nonisolated struct AppScopeRequest: Sendable, Hashable, Identifiable {
    public var scope: String
    public var reason: String
    public var id: String { scope }

    public init(scope: String, reason: String) {
        self.scope = scope
        self.reason = reason
    }

    static func list(_ json: AppJSON?) -> [AppScopeRequest] {
        (json?.objectValue ?? [:]).sorted { $0.key < $1.key }.map { AppScopeRequest(scope: $0.key, reason: $0.value.stringValue ?? "") }
    }
}
