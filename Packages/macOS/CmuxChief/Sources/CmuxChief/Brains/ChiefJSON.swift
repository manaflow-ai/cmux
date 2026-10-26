import Foundation

/// A JSON value the brain drivers read from and write to agent CLIs.
///
/// Claude Code's stream-json and Codex's app-server JSON-RPC are both one
/// JSON object per line with open-ended shapes, so the drivers read them as
/// a plain value tree instead of a `Codable` model per message.
///
/// ```swift
/// let line = try ChiefJSON(parsing: Data(#"{"type":"result","is_error":false}"#.utf8))
/// line["type"]?.string // "result"
/// ```
enum ChiefJSON: Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([ChiefJSON])
    case object([String: ChiefJSON])

    /// Parses one JSON document.
    ///
    /// - Parameter data: UTF-8 JSON text.
    /// - Throws: A decoding error when `data` is not JSON.
    init(parsing data: Data) throws {
        self = try JSONDecoder().decode(ChiefJSON.self, from: data)
    }

    /// The value as one line of compact JSON with a trailing newline.
    var line: Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        var data = (try? encoder.encode(self)) ?? Data("null".utf8)
        data.append(0x0A)
        return data
    }

    /// The value as compact JSON text.
    var compactText: String {
        String(decoding: line.dropLast(), as: UTF8.self)
    }

    /// The member `key` of an object, nil for a missing key or a non-object.
    subscript(key: String) -> ChiefJSON? {
        guard case .object(let members) = self else { return nil }
        return members[key]
    }

    /// The string, nil for any other kind.
    var string: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    /// The boolean, nil for any other kind.
    var bool: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    /// The number, nil for any other kind.
    var number: Double? {
        if case .number(let value) = self { return value }
        return nil
    }

    /// The elements, nil for any other kind.
    var array: [ChiefJSON]? {
        if case .array(let value) = self { return value }
        return nil
    }

    /// The members, nil for any other kind.
    var object: [String: ChiefJSON]? {
        if case .object(let value) = self { return value }
        return nil
    }

    /// Whether the value is JSON null.
    var isNull: Bool {
        if case .null = self { return true }
        return false
    }
}

extension ChiefJSON: Codable {
    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([ChiefJSON].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: ChiefJSON].self))
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let value):
            try container.encode(value)
        case .number(let value):
            // JSON-RPC ids and counts are integers; keep them integral on the wire.
            if value.rounded() == value, abs(value) < 9_007_199_254_740_992 {
                try container.encode(Int64(value))
            } else {
                try container.encode(value)
            }
        case .string(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        }
    }
}

extension ChiefJSON: ExpressibleByStringLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral, ExpressibleByNilLiteral {
    init(stringLiteral value: String) { self = .string(value) }
    init(booleanLiteral value: Bool) { self = .bool(value) }
    init(integerLiteral value: Int) { self = .number(Double(value)) }
    init(arrayLiteral elements: ChiefJSON...) { self = .array(elements) }
    init(nilLiteral: ()) { self = .null }
    init(dictionaryLiteral elements: (String, ChiefJSON)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
}

/// Splits a byte stream into newline-terminated lines.
///
/// A pipe read can end mid-line or carry several lines; the framer keeps the
/// unterminated tail until the rest arrives. Empty lines are dropped and a
/// trailing carriage return is removed.
///
/// ```swift
/// var framer = ChiefLineFramer()
/// framer.append(Data("{\"a\":1}\n{\"b\"".utf8)) // one line
/// framer.append(Data(":2}\n".utf8))            // the second line
/// ```
struct ChiefLineFramer: Sendable {
    private var buffer = Data()

    /// Adds bytes and returns every line they complete.
    ///
    /// - Parameter data: The next bytes from the stream.
    /// - Returns: Complete lines, without their terminators.
    mutating func append(_ data: Data) -> [Data] {
        buffer.append(data)
        var lines: [Data] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            if let trimmed = Self.trim(Data(line)) { lines.append(trimmed) }
        }
        return lines
    }

    /// Returns the unterminated tail at end of stream, if any.
    mutating func finish() -> Data? {
        defer { buffer = Data() }
        return Self.trim(buffer)
    }

    private static func trim(_ line: Data) -> Data? {
        var line = line
        if line.last == 0x0D { line.removeLast() }
        return line.isEmpty ? nil : line
    }
}
