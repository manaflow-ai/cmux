import CoreFoundation
import Foundation

/// Partial Dynamic Notch appearance values used by one notification.
public struct DynamicNotchAppearanceOverrides: Sendable, Equatable, Hashable {
    let values: [DynamicNotchAppearanceToken: DynamicNotchAppearanceValue]

    /// Creates an empty override that inherits every global value.
    public init() {
        values = [:]
    }

    init(values: [DynamicNotchAppearanceToken: DynamicNotchAppearanceValue]) {
        self.values = values
    }

    /// Parses and validates a JSON object whose keys are appearance tokens.
    ///
    /// Numbers, booleans, and colors retain their JSON types. A color accepts
    /// `null`, `system`, or `#RRGGBB`.
    ///
    /// - Parameter jsonObject: A Foundation JSON object.
    public init(jsonObject: Any) throws {
        guard let object = jsonObject as? [String: Any] else {
            throw DynamicNotchAppearanceParseError.invalid
        }
        var parsed: [DynamicNotchAppearanceToken: DynamicNotchAppearanceValue] = [:]
        parsed.reserveCapacity(object.count)
        for (rawToken, rawValue) in object {
            guard let token = DynamicNotchAppearanceToken(rawValue: rawToken) else {
                throw DynamicNotchAppearanceParseError.invalid
            }
            parsed[token] = try Self.parseJSONValue(rawValue, for: token)
        }
        values = parsed
    }

    /// Parses repeated CLI assignments such as `expandedWidth=560`.
    ///
    /// - Parameter assignments: Appearance assignments using canonical token names.
    public init(assignments: [String]) throws {
        var parsed: [DynamicNotchAppearanceToken: DynamicNotchAppearanceValue] = [:]
        parsed.reserveCapacity(assignments.count)
        for assignment in assignments {
            guard let separator = assignment.firstIndex(of: "=") else {
                throw DynamicNotchAppearanceParseError.invalid
            }
            let rawToken = String(assignment[..<separator])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let rawValue = String(assignment[assignment.index(after: separator)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let token = DynamicNotchAppearanceToken(rawValue: rawToken) else {
                throw DynamicNotchAppearanceParseError.invalid
            }
            parsed[token] = try Self.parseStringValue(rawValue, for: token)
        }
        values = parsed
    }

    /// Whether this override inherits every global value.
    public var isEmpty: Bool {
        values.isEmpty
    }

    /// Returns the override for one token, or `nil` when it is inherited.
    public subscript(token: DynamicNotchAppearanceToken) -> DynamicNotchAppearanceValue? {
        values[token]
    }

    /// Returns a merged override where values from `other` win.
    ///
    /// - Parameter other: Later overrides, such as direct `--style` flags.
    public func merging(_ other: DynamicNotchAppearanceOverrides) -> DynamicNotchAppearanceOverrides {
        DynamicNotchAppearanceOverrides(values: values.merging(other.values) { _, later in later })
    }

    /// A JSONSerialization-compatible object for the socket payload.
    public var foundationJSONObject: [String: Any] {
        Dictionary(uniqueKeysWithValues: values.map { token, value in
            (token.rawValue, Self.foundationValue(value))
        })
    }

    /// Canonical strings suitable for property-list dictionary storage.
    var serializedValues: [String: String] {
        Dictionary(uniqueKeysWithValues: values.map { token, value in
            (token.rawValue, Self.serializedValue(value))
        })
    }

    /// JSON Schema for every supported appearance token.
    public static var jsonSchemaObject: [String: Any] {
        let properties = Dictionary(uniqueKeysWithValues:
            DynamicNotchAppearanceToken.allCases.map { token in
                (token.rawValue, schema(for: token))
            }
        )
        return [
            "type": "object",
            "additionalProperties": false,
            "properties": properties,
        ]
    }

    /// Pretty-printed JSON Schema for agent discovery.
    public static var jsonSchemaString: String {
        guard let data = try? JSONSerialization.data(
            withJSONObject: jsonSchemaObject,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        ) else {
            return #"{"type":"object","additionalProperties":false}"#
        }
        return String(decoding: data, as: UTF8.self)
    }

    static func parseSerializedValues(
        _ serialized: [String: String]
    ) throws -> DynamicNotchAppearanceOverrides {
        var parsed: [DynamicNotchAppearanceToken: DynamicNotchAppearanceValue] = [:]
        parsed.reserveCapacity(serialized.count)
        for (rawToken, rawValue) in serialized {
            guard let token = DynamicNotchAppearanceToken(rawValue: rawToken) else {
                throw DynamicNotchAppearanceParseError.invalid
            }
            parsed[token] = try parseStringValue(rawValue, for: token)
        }
        return DynamicNotchAppearanceOverrides(values: parsed)
    }

    private static func parseJSONValue(
        _ rawValue: Any,
        for token: DynamicNotchAppearanceToken
    ) throws -> DynamicNotchAppearanceValue {
        let value: DynamicNotchAppearanceValue
        switch token.valueKind {
        case .number:
            guard let number = rawValue as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID() else {
                throw DynamicNotchAppearanceParseError.invalid
            }
            value = .number(number.doubleValue)
        case .integer:
            guard let number = rawValue as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue.isFinite,
                  number.doubleValue.rounded() == number.doubleValue,
                  number.doubleValue >= Double(Int.min),
                  number.doubleValue <= Double(Int.max) else {
                throw DynamicNotchAppearanceParseError.invalid
            }
            value = .integer(Int(number.doubleValue))
        case .boolean:
            guard let number = rawValue as? NSNumber,
                  CFGetTypeID(number) == CFBooleanGetTypeID() else {
                throw DynamicNotchAppearanceParseError.invalid
            }
            value = .boolean(number.boolValue)
        case .color:
            if rawValue is NSNull {
                value = .color(.system)
            } else if let string = rawValue as? String,
                      let color = DynamicNotchAppearanceColor(rawValue: string) {
                value = .color(color)
            } else {
                throw DynamicNotchAppearanceParseError.invalid
            }
        }
        guard token.accepts(value) else {
            throw DynamicNotchAppearanceParseError.invalid
        }
        return value
    }

    private static func parseStringValue(
        _ rawValue: String,
        for token: DynamicNotchAppearanceToken
    ) throws -> DynamicNotchAppearanceValue {
        let value: DynamicNotchAppearanceValue
        switch token.valueKind {
        case .number:
            guard let number = Double(rawValue) else {
                throw DynamicNotchAppearanceParseError.invalid
            }
            value = .number(number)
        case .integer:
            guard let integer = Int(rawValue) else {
                throw DynamicNotchAppearanceParseError.invalid
            }
            value = .integer(integer)
        case .boolean:
            switch rawValue.lowercased() {
            case "true":
                value = .boolean(true)
            case "false":
                value = .boolean(false)
            default:
                throw DynamicNotchAppearanceParseError.invalid
            }
        case .color:
            guard let color = DynamicNotchAppearanceColor(rawValue: rawValue) else {
                throw DynamicNotchAppearanceParseError.invalid
            }
            value = .color(color)
        }
        guard token.accepts(value) else {
            throw DynamicNotchAppearanceParseError.invalid
        }
        return value
    }

    private static func foundationValue(_ value: DynamicNotchAppearanceValue) -> Any {
        switch value {
        case .number(let number):
            number
        case .integer(let integer):
            integer
        case .boolean(let boolean):
            boolean
        case .color(.system):
            NSNull()
        case .color(.hex(let color)):
            color
        }
    }

    private static func serializedValue(_ value: DynamicNotchAppearanceValue) -> String {
        switch value {
        case .number(let number):
            String(number)
        case .integer(let integer):
            String(integer)
        case .boolean(let boolean):
            String(boolean)
        case .color(let color):
            color.rawValue
        }
    }

    private static func schema(for token: DynamicNotchAppearanceToken) -> [String: Any] {
        let defaultValue = foundationValue(token.defaultValue)
        switch token.valueKind {
        case .number(let minimum, let maximum, _):
            return [
                "type": "number",
                "minimum": minimum,
                "maximum": maximum,
                "default": defaultValue,
            ]
        case .integer(let minimum, let maximum):
            return [
                "type": "integer",
                "minimum": minimum,
                "maximum": maximum,
                "default": defaultValue,
            ]
        case .boolean:
            return [
                "type": "boolean",
                "default": defaultValue,
            ]
        case .color:
            return [
                "default": defaultValue,
                "oneOf": [
                    ["type": "null"],
                    [
                        "type": "string",
                        "anyOf": [
                            ["const": "system"],
                            ["pattern": "^#[0-9A-Fa-f]{6}$"],
                        ],
                    ],
                ],
            ]
        }
    }
}

private enum DynamicNotchAppearanceParseError: Error {
    case invalid
}
