import Foundation

/// Validated per-display overrides for synthetic Dynamic Notch anchors.
///
/// Values are serialized as strings because the settings-file reconciler's
/// managed-defaults snapshot supports string dictionaries. Callers still read
/// and write positions as numbers from zero (left) through one (right).
public enum DynamicNotchDisplayPositionSettings {
    public static func position(
        for displayKey: String,
        in serializedPositions: [String: String]
    ) -> Double? {
        guard let rawValue = serializedPositions[displayKey],
            let value = Double(rawValue),
            isValid(value)
        else {
            return nil
        }
        return value
    }

    public static func setting(
        _ position: Double,
        for displayKey: String,
        in serializedPositions: [String: String]
    ) -> [String: String] {
        guard !displayKey.isEmpty, isValid(position) else {
            return serializedPositions
        }
        var result = serializedPositions
        result[displayKey] = String(position)
        return result
    }

    public static func removing(
        displayKey: String,
        from serializedPositions: [String: String]
    ) -> [String: String] {
        var result = serializedPositions
        result.removeValue(forKey: displayKey)
        return result
    }

    public static func serializedPositions(
        fromJSONObject raw: Any?
    ) -> [String: String]? {
        guard let dictionary = raw as? [String: Any] else { return nil }
        var result: [String: String] = [:]
        result.reserveCapacity(dictionary.count)
        for (displayKey, rawPosition) in dictionary {
            guard !displayKey.isEmpty,
                let number = rawPosition as? NSNumber,
                CFGetTypeID(number) != CFBooleanGetTypeID(),
                isValid(number.doubleValue)
            else {
                return nil
            }
            result[displayKey] = String(number.doubleValue)
        }
        return result
    }

    public static func jsonObject(
        from serializedPositions: [String: String]
    ) -> [String: Double] {
        serializedPositions.reduce(into: [:]) { result, entry in
            guard let value = Double(entry.value), isValid(value) else { return }
            result[entry.key] = value
        }
    }

    private static func isValid(_ value: Double) -> Bool {
        value.isFinite && (0...1).contains(value)
    }
}
