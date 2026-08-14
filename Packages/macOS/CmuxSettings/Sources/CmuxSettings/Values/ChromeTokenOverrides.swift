/// A validated set of user-provided token colors.
///
/// The wire representation is a flat object such as
/// `{ "accent": "#89B4FA" }`. Decoding is all-or-nothing: an unknown token,
/// malformed hex value, or non-string value makes the complete override
/// payload invalid and the resolver falls back to the theme unchanged. This
/// fail-closed behavior prevents a typo from producing a partially themed UI.
public struct ChromeTokenOverrides: Sendable, Equatable {
    /// Decoded token values keyed by their semantic token identifier.
    public let values: [ChromeToken: ChromeColor]

    /// Creates an override set from already validated token values.
    ///
    /// - Parameter values: Values to layer over a built-in theme.
    public init(_ values: [ChromeToken: ChromeColor] = [:]) {
        self.values = values
    }

    /// Returns the override for `token`, if one was supplied.
    public subscript(_ token: ChromeToken) -> ChromeColor? {
        values[token]
    }

    /// An override set that leaves every built-in token unchanged.
    public static let empty = ChromeTokenOverrides()

    /// Creates overrides from the user-facing token/hex object.
    /// Returns `nil` when any entry is invalid.
    public init?(hexValues: [String: String]) {
        var decoded: [ChromeToken: ChromeColor] = [:]
        decoded.reserveCapacity(hexValues.count)
        for (rawToken, rawColor) in hexValues {
            guard let token = ChromeToken(rawValue: rawToken),
                  let color = ChromeColor(hex: rawColor) else {
                return nil
            }
            decoded[token] = color
        }
        self.values = decoded
    }

    /// Returns the canonical flat config object.
    public var hexValues: [String: String] {
        Dictionary(uniqueKeysWithValues: values.map { ($0.rawValue, $1.hex) })
    }
}

extension ChromeTokenOverrides: SettingCodable {
    /// Decodes the flat token map used by UserDefaults-backed config seams.
    public static func decodeFromUserDefaults(_ raw: Any?) -> ChromeTokenOverrides? {
        decodeDictionary(raw)
    }

    /// Encodes the override map for UserDefaults storage.
    public func encodeForUserDefaults() -> Any {
        hexValues
    }

    /// Decodes the flat token map used in `cmux.json`.
    public static func decodeFromJSON(_ raw: Any?) -> ChromeTokenOverrides? {
        decodeDictionary(raw)
    }

    /// Encodes the override map for JSON storage.
    public func encodeForJSON() -> Any {
        hexValues
    }

    private static func decodeDictionary(_ raw: Any?) -> ChromeTokenOverrides? {
        guard let rawDictionary = raw as? [String: Any] else { return nil }
        var strings: [String: String] = [:]
        strings.reserveCapacity(rawDictionary.count)
        for (key, value) in rawDictionary {
            guard let value = value as? String else { return nil }
            strings[key] = value
        }
        return ChromeTokenOverrides(hexValues: strings)
    }
}
