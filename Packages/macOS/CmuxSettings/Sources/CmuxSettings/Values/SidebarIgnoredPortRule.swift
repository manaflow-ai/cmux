import Foundation

/// One exact port or inclusive port range omitted from sidebar port badges.
public struct SidebarIgnoredPortRule: Sendable, Equatable {
    /// Validated inclusive bounds for this rule.
    private let range: ClosedRange<Int>

    /// The exact port when this rule was configured as one port.
    private let exactPort: Int?

    /// The IANA dynamic/private range used for OS-assigned ephemeral ports.
    static let operatingSystemEphemeralRange = 49_152...65_535

    /// The validated rule for the IANA dynamic/private port range.
    static let operatingSystemEphemeralRangeRule = Self(
        range: operatingSystemEphemeralRange,
        exactPort: nil
    )

    /// Creates a rule that omits one exact valid port.
    ///
    /// - Parameter port: A port in `1...65535`.
    public init?(port: Int) {
        guard (1...65_535).contains(port) else { return nil }
        range = port...port
        exactPort = port
    }

    /// Creates a rule that omits one inclusive range of valid ports.
    ///
    /// - Parameter range: A range whose bounds are both in `1...65535`.
    public init?(range: ClosedRange<Int>) {
        guard (1...65_535).contains(range.lowerBound),
              (1...65_535).contains(range.upperBound) else {
            return nil
        }
        self.range = range
        exactPort = nil
    }

    /// Creates a rule from already validated bounds and representation.
    private init(range: ClosedRange<Int>, exactPort: Int?) {
        self.range = range
        self.exactPort = exactPort
    }

    /// The validated inclusive bounds used to build a visibility-policy index.
    var inclusiveRange: ClosedRange<Int> {
        range
    }

    /// The canonical text representation used for range configuration and persistence.
    public var canonicalText: String {
        if let exactPort {
            return String(exactPort)
        }
        return "\(range.lowerBound)-\(range.upperBound)"
    }

    /// Parses a textual rule, optionally accepting an exact-port form.
    private init?(text rawValue: String, acceptsExactPort: Bool) {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if acceptsExactPort, let port = Int(value) {
            self.init(port: port)
            return
        }

        let bounds = value.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard bounds.count == 2,
              let lowerBound = Int(bounds[0].trimmingCharacters(in: .whitespaces)),
              let upperBound = Int(bounds[1].trimmingCharacters(in: .whitespaces)),
              (1...65_535).contains(lowerBound),
              (1...65_535).contains(upperBound),
              lowerBound <= upperBound else {
            return nil
        }
        self.init(range: lowerBound...upperBound)
    }
}

// SettingCodable requires type-level codec witnesses; these static members are
// protocol entry points, not a namespace or shared runtime state.
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
        return Self(text: value, acceptsExactPort: true)
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
        return Self(text: value, acceptsExactPort: false)
    }

    /// Encodes exact ports as integers and ranges as canonical strings.
    public func encodeForJSON() -> Any {
        if let exactPort {
            return exactPort
        }
        return canonicalText
    }
}
