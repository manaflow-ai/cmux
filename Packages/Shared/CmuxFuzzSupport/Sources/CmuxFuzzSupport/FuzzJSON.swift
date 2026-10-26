import Foundation

/// A JSON value a property test builds and writes as one wire line: the fields a
/// decoder reads, with the right type or a chosen wrong one, among random others.
/// It writes through `JSONEncoder`, so 64-bit integers keep every digit (an
/// `NSNumber` through `JSONSerialization` can lose them) and keys come out sorted.
public indirect enum FuzzJSON: Sendable, Equatable, Encodable, CustomStringConvertible {
    case null
    case bool(Bool)
    case int(Int64)
    case uint(UInt64)
    /// A finite number; a non-finite one makes ``data()`` throw.
    case double(Double)
    case string(String)
    case array([FuzzJSON])
    case object([String: FuzzJSON])

    /// The JSON type of a value, to draw one of a given type or of any other.
    public enum Kind: Sendable, Equatable, CaseIterable {
        case null, bool, number, string, array, object
    }

    /// Characters for random text: quotes, escapes, controls, a NUL, a byte-order mark,
    /// combining and astral characters.
    public static let alphabet: [Character] = [
        "a", "z", "Q", "7", "-", "_", ".", " ", "é", "✓", "\"", "\\", "/", "\t", "\n", "\u{0}", "\u{FEFF}",
        "\u{301}", "\u{1F600}", "{", "}", "%", "?", "#",
    ]

    /// Tokens for ``FuzzMutator``'s dictionary: JSON structure, literals, numbers no
    /// 64-bit type holds, and escapes of a NUL and a lone surrogate.
    public static let tokens: [Data] = [
        "{", "}", "[", "]", "\"", ":", ",", "null", "true", "false", "-0", "1e400", "-1e400", "0.5",
        "18446744073709551616", "-9223372036854775809", "\\u0000", "\\ud800", "\\\"", "\u{FEFF}",
    ].map { Data($0.utf8) }

    public var kind: Kind {
        switch self {
        case .null: .null
        case .bool: .bool
        case .int, .uint, .double: .number
        case .string: .string
        case .array: .array
        case .object: .object
        }
    }

    /// This value as one line of UTF-8 JSON, object keys sorted. A string's newline is
    /// escaped, so the line never holds one.
    public func data() throws(FuzzError) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        do {
            return try encoder.encode(self)
        } catch {
            throw FuzzError.property("the generator built a value JSON cannot hold: \(error)", location: "FuzzJSON")
        }
    }

    /// ``data()`` as a string.
    public func text() throws(FuzzError) -> String {
        String(decoding: try data(), as: UTF8.self)
    }

    /// This object with `value` at `key`; any other value stays as it is.
    public func setting(_ key: String, _ value: FuzzJSON?) -> FuzzJSON {
        guard case var .object(fields) = self else { return self }
        fields[key] = value
        return .object(fields)
    }

    public func encode(to encoder: any Encoder) throws {
        switch self {
        case let .object(fields):
            var container = encoder.container(keyedBy: Key.self)
            for (key, value) in fields { try container.encode(value, forKey: Key(stringValue: key)) }
        case let .array(items):
            var container = encoder.unkeyedContainer()
            for item in items { try container.encode(item) }
        case .null:
            var container = encoder.singleValueContainer()
            try container.encodeNil()
        case let .bool(value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case let .int(value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case let .uint(value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case let .double(value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case let .string(value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        }
    }

    /// The JSON line, for failure messages.
    public var description: String { (try? text()) ?? "<a value JSON cannot hold>" }

    struct Key: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }
}

extension FuzzJSON {
    /// Between 0 and `limit - 1` characters of ``alphabet``.
    public static func randomString(_ rng: inout FuzzRNG, limit: Int = 16) -> String {
        rng.text(alphabet, limit)
    }

    /// A random value nested at most `depth` deep.
    public static func random(_ rng: inout FuzzRNG, depth: Int = 2) -> FuzzJSON {
        random(&rng, of: Kind.allCases, depth: depth)
    }

    /// A random value of one of `kinds` (null when `kinds` is empty). Arrays and objects are
    /// empty at `depth` 0; object keys start with `x`, so they never name a field a decoder reads.
    public static func random(_ rng: inout FuzzRNG, of kinds: [Kind], depth: Int = 1) -> FuzzJSON {
        switch rng.element(of: kinds) ?? .null {
        case .null:
            return .null
        case .bool:
            return .bool(rng.bool())
        case .number:
            switch rng.below(4) {
            case 0: return .int(Int64(rng.int(in: -1_000...1_000)))
            case 1: return .int(rng.oneIn(2) ? .min : .max)
            case 2: return .uint(rng.next())
            default: return .double(rng.double(in: -1e6...1e6) + 0.5)
            }
        case .string:
            return .string(randomString(&rng))
        case .array:
            let count = depth > 0 ? rng.below(4) : 0
            return .array((0..<count).map { _ in random(&rng, depth: depth - 1) })
        case .object:
            var fields: [String: FuzzJSON] = [:]
            for _ in 0..<(depth > 0 ? rng.below(4) : 0) {
                fields["x" + rng.text(["a", "b", "_", "1"], 6)] = random(&rng, depth: depth - 1)
            }
            return .object(fields)
        }
    }

    /// A random value whose type is not one of `kinds`: a field a decoder must refuse or skip.
    public static func random(_ rng: inout FuzzRNG, notOf kinds: [Kind], depth: Int = 1) -> FuzzJSON {
        random(&rng, of: Kind.allCases.filter { !kinds.contains($0) }, depth: depth)
    }
}
