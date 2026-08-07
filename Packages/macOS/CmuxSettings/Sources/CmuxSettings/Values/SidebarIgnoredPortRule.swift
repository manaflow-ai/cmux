import Foundation

/// One exact port or inclusive port range omitted from sidebar port badges.
public struct SidebarIgnoredPortRule: Sendable, Equatable {
    /// Validated storage for an exact port or inclusive range.
    private enum Storage: Sendable, Equatable {
        /// One exact port.
        case port(Int)

        /// One inclusive port range.
        case range(ClosedRange<Int>)
    }

    /// The validated representation of this rule.
    private let storage: Storage

    /// The IANA dynamic/private range used for OS-assigned ephemeral ports.
    static let operatingSystemEphemeralRange = 49_152...65_535

    /// The validated rule for the IANA dynamic/private port range.
    static let operatingSystemEphemeralRangeRule = Self(
        storage: .range(operatingSystemEphemeralRange)
    )

    /// Creates a rule that omits one exact valid port.
    ///
    /// - Parameter port: A port in `1...65535`.
    public init?(port: Int) {
        guard (1...65_535).contains(port) else { return nil }
        storage = .port(port)
    }

    /// Creates a rule that omits one inclusive range of valid ports.
    ///
    /// - Parameter range: A range whose bounds are both in `1...65535`.
    public init?(range: ClosedRange<Int>) {
        guard (1...65_535).contains(range.lowerBound),
              (1...65_535).contains(range.upperBound) else {
            return nil
        }
        storage = .range(range)
    }

    /// Creates a rule from already validated internal storage.
    private init(storage: Storage) {
        self.storage = storage
    }

    /// The validated inclusive bounds used to build a visibility-policy index.
    var inclusiveRange: ClosedRange<Int> {
        switch storage {
        case .port(let port):
            port...port
        case .range(let range):
            range
        }
    }

    /// The canonical text representation used for range configuration and persistence.
    public var canonicalText: String {
        switch storage {
        case .port(let port):
            String(port)
        case .range(let range):
            "\(range.lowerBound)-\(range.upperBound)"
        }
    }

    /// Parses the canonical property-list representation of a rule.
    private static func parsedPersistedText(_ rawValue: String) -> Self? {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if let port = Int(value) {
            return Self(port: port)
        }

        return parsedRangeText(value)
    }

    /// Parses a textual inclusive range after its representation is selected.
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
        return Self(range: lowerBound...upperBound)
    }
}

extension SidebarIgnoredPortRule: SettingCodable {
    /// Decodes a persisted exact port or inclusive range.
    public static func decodeFromUserDefaults(_ raw: Any?) -> Self? {
        if let number = raw as? NSNumber {
            guard CFGetTypeID(number) != CFBooleanGetTypeID(),
                  let port = Int(exactly: number) else {
                return nil
            }
            return Self(port: port)
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
            return Self(port: port)
        }
        guard let value = String.decodeFromJSON(raw) else { return nil }
        return parsedRangeText(value.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Encodes exact ports as integers and ranges as canonical strings.
    public func encodeForJSON() -> Any {
        switch storage {
        case .port(let port):
            port
        case .range:
            canonicalText
        }
    }
}
