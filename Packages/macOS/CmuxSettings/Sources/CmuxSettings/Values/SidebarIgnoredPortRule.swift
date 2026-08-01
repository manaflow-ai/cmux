import Foundation

/// One exact port or inclusive port range omitted from sidebar port badges.
public enum SidebarIgnoredPortRule: Sendable, Equatable {
    /// Omits one exact port.
    case port(Int)

    /// Omits every port in an inclusive range.
    case range(ClosedRange<Int>)

    /// The canonical text representation used for range configuration and persistence.
    public var canonicalText: String {
        switch self {
        case .port(let port):
            String(port)
        case .range(let range):
            "\(range.lowerBound)-\(range.upperBound)"
        }
    }

    /// Returns whether this rule omits `port` from sidebar publication.
    public func contains(_ port: Int) -> Bool {
        switch self {
        case .port(let ignoredPort):
            port == ignoredPort
        case .range(let ignoredRange):
            ignoredRange.contains(port)
        }
    }

    private static func validatedPort(_ port: Int) -> Self? {
        guard (1...65_535).contains(port) else { return nil }
        return .port(port)
    }

    private static func parsedPersistedText(_ rawValue: String) -> Self? {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if let port = Int(value) {
            return validatedPort(port)
        }

        return parsedRangeText(value)
    }

    private static func parsedRangeText(_ rawValue: String) -> Self? {
        let bounds = rawValue.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard bounds.count == 2,
              let lowerBound = Int(bounds[0].trimmingCharacters(in: .whitespaces)),
              let upperBound = Int(bounds[1].trimmingCharacters(in: .whitespaces)),
              (1...65_535).contains(lowerBound),
              (1...65_535).contains(upperBound),
              lowerBound <= upperBound else {
            return nil
        }
        return .range(lowerBound...upperBound)
    }
}

extension SidebarIgnoredPortRule: SettingCodable {
    /// Decodes a persisted exact port or inclusive range.
    public static func decodeFromUserDefaults(_ raw: Any?) -> Self? {
        if let port = Int.decodeFromUserDefaults(raw) {
            return validatedPort(port)
        }
        guard let value = String.decodeFromUserDefaults(raw) else { return nil }
        return parsedPersistedText(value)
    }

    /// Encodes the rule into a property-list-safe canonical string.
    public func encodeForUserDefaults() -> Any {
        canonicalText
    }

    /// Decodes an exact integer port or an inclusive `"start-end"` JSON range.
    public static func decodeFromJSON(_ raw: Any?) -> Self? {
        if let port = Int.decodeFromJSON(raw) {
            return validatedPort(port)
        }
        guard let value = String.decodeFromJSON(raw) else { return nil }
        return parsedRangeText(value.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Encodes exact ports as integers and ranges as canonical strings.
    public func encodeForJSON() -> Any {
        switch self {
        case .port(let port):
            port
        case .range:
            canonicalText
        }
    }
}
