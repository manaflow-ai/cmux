import Foundation

/// A complete, validated Dynamic Notch notification theme.
public struct DynamicNotchAppearance: SettingCodable, Sendable, Equatable {
    private var values: [DynamicNotchAppearanceToken: DynamicNotchAppearanceValue]

    /// Creates the built-in appearance that matches cmux's original layout.
    public init() {
        values = Dictionary(uniqueKeysWithValues:
            DynamicNotchAppearanceToken.allCases.map { ($0, $0.defaultValue) }
        )
    }

    private init(values: [DynamicNotchAppearanceToken: DynamicNotchAppearanceValue]) {
        self.values = values
    }

    /// Returns the resolved value for a token.
    public subscript(token: DynamicNotchAppearanceToken) -> DynamicNotchAppearanceValue {
        values[token] ?? token.defaultValue
    }

    /// Applies a partial per-notification override.
    ///
    /// - Parameter overrides: Values that should replace global settings.
    public func applying(_ overrides: DynamicNotchAppearanceOverrides) -> DynamicNotchAppearance {
        DynamicNotchAppearance(values: values.merging(overrides.values) { _, override in override })
    }

    /// Returns a copy with one validated token changed.
    ///
    /// Invalid programmatic values leave the appearance unchanged.
    ///
    /// - Parameters:
    ///   - value: The new token value.
    ///   - token: The token to replace.
    public func replacing(
        _ value: DynamicNotchAppearanceValue,
        for token: DynamicNotchAppearanceToken
    ) -> DynamicNotchAppearance {
        guard token.accepts(value) else { return self }
        var copy = self
        copy.values[token] = value
        return copy
    }

    /// Returns a copy with one token restored to its built-in value.
    ///
    /// - Parameter token: The token to reset.
    public func resetting(_ token: DynamicNotchAppearanceToken) -> DynamicNotchAppearance {
        replacing(token.defaultValue, for: token)
    }

    /// Returns whether every token still has its built-in value.
    public var isDefault: Bool {
        DynamicNotchAppearanceToken.allCases.allSatisfy { self[$0] == $0.defaultValue }
    }

    public static func decodeFromUserDefaults(_ raw: Any?) -> DynamicNotchAppearance? {
        guard let serialized = raw as? [String: String],
              let overrides = try? DynamicNotchAppearanceOverrides.parseSerializedValues(serialized) else {
            return nil
        }
        return DynamicNotchAppearance().applying(overrides)
    }

    public func encodeForUserDefaults() -> Any {
        DynamicNotchAppearanceOverrides(values: values).serializedValues
    }

    public static func decodeFromJSON(_ raw: Any?) -> DynamicNotchAppearance? {
        guard let raw,
              let overrides = try? DynamicNotchAppearanceOverrides(jsonObject: raw) else {
            return nil
        }
        return DynamicNotchAppearance().applying(overrides)
    }

    public func encodeForJSON() -> Any {
        DynamicNotchAppearanceOverrides(values: values).foundationJSONObject
    }
}
