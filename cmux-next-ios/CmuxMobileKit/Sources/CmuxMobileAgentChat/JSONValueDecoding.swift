import Foundation

// A `Decoder` over a `JSONValue`: a value already parsed (an acpmux record) decodes into its
// type by walking the tree once. The way it went before, the value was written back out as
// JSON text and that text parsed again (`JSONDecoder().decode(T.self, from: JSONEncoder().encode(value))`),
// so a 2 MB tool output was encoded and parsed a second and third time on the main actor.
//
// It decodes as `JSONDecoder` does with its default strategies: `Data` from base64, `URL` from a
// string, `Date` by its own `Codable` (seconds since 2001), `Decimal` from a number, integers
// only from numbers they hold exactly, and no conversion between JSON types.

extension JSONValue {
    /// This value decoded as `type`, as `JSONDecoder` decodes the same JSON text.
    public func decoded<T: Decodable>(as type: T.Type = T.self) throws -> T {
        try JSONValueDecoding.unbox(self, as: type, path: [])
    }
}

enum JSONValueDecoding {
    static func unbox<T: Decodable>(_ value: JSONValue, as type: T.Type, path: [any CodingKey]) throws -> T {
        if T.self == JSONValue.self { return cast(value) }
        if T.self == String.self {
            guard case .string(let string) = value else { throw mismatch(T.self, value, path) }
            return cast(string)
        }
        if T.self == Data.self {
            guard case .string(let string) = value else { throw mismatch(T.self, value, path) }
            guard let data = Data(base64Encoded: string) else {
                throw DecodingError.dataCorrupted(.init(codingPath: path, debugDescription: "Encountered Data is not valid Base64."))
            }
            return cast(data)
        }
        if T.self == URL.self {
            guard case .string(let string) = value else { throw mismatch(T.self, value, path) }
            guard let url = URL(string: string) else {
                throw DecodingError.dataCorrupted(.init(codingPath: path, debugDescription: "Invalid URL string."))
            }
            return cast(url)
        }
        if T.self == Decimal.self {
            guard case .number(let number) = value else { throw mismatch(T.self, value, path) }
            return cast(Decimal(number))
        }
        return try T(from: ValueDecoder(value: value, codingPath: path))
    }

    /// `value` as `T`, which the caller checked it is.
    private static func cast<T>(_ value: Any) -> T { value as! T }

    static func mismatch(_ type: Any.Type, _ value: JSONValue, _ path: [any CodingKey]) -> DecodingError {
        let found = switch value {
        case .null: "null"
        case .bool: "a bool"
        case .number: "a number"
        case .string: "a string"
        case .array: "an array"
        case .object: "a dictionary"
        }
        return .typeMismatch(type, .init(codingPath: path, debugDescription: "Expected to decode \(type) but found \(found) instead."))
    }

    static func bool(_ value: JSONValue, _ path: [any CodingKey]) throws -> Bool {
        guard case .bool(let bool) = value else { throw mismatch(Bool.self, value, path) }
        return bool
    }

    static func string(_ value: JSONValue, _ path: [any CodingKey]) throws -> String {
        guard case .string(let string) = value else { throw mismatch(String.self, value, path) }
        return string
    }

    static func double(_ value: JSONValue, _ path: [any CodingKey]) throws -> Double {
        guard case .number(let number) = value else { throw mismatch(Double.self, value, path) }
        return number
    }

    static func float(_ value: JSONValue, _ path: [any CodingKey]) throws -> Float {
        let number = try double(value, path)
        guard number.isFinite, abs(number) <= Double(Float.greatestFiniteMagnitude) else {
            throw DecodingError.dataCorrupted(.init(codingPath: path, debugDescription: "Number \(number) does not fit in Float."))
        }
        return Float(number)
    }

    static func integer<I: FixedWidthInteger>(_ value: JSONValue, _ path: [any CodingKey]) throws -> I {
        let number = try double(value, path)
        guard let integer = I(exactly: number) else {
            throw DecodingError.dataCorrupted(.init(codingPath: path, debugDescription: "Number \(number) is not representable in Swift."))
        }
        return integer
    }
}

/// A coding key for an array's index.
private struct IndexKey: CodingKey {
    let intValue: Int?
    let stringValue: String
    init(_ index: Int) {
        intValue = index
        stringValue = "Index \(index)"
    }
    init?(stringValue: String) { return nil }
    init?(intValue: Int) { self.init(intValue) }
}

private struct ValueDecoder: Decoder {
    let value: JSONValue
    let codingPath: [any CodingKey]
    var userInfo: [CodingUserInfoKey: Any] { [:] }

    func container<Key: CodingKey>(keyedBy type: Key.Type) throws -> KeyedDecodingContainer<Key> {
        guard case .object(let object) = value else {
            throw JSONValueDecoding.mismatch([String: JSONValue].self, value, codingPath)
        }
        return KeyedDecodingContainer(KeyedValues<Key>(object: object, codingPath: codingPath))
    }

    func unkeyedContainer() throws -> any UnkeyedDecodingContainer {
        guard case .array(let array) = value else {
            throw JSONValueDecoding.mismatch([JSONValue].self, value, codingPath)
        }
        return UnkeyedValues(array: array, codingPath: codingPath)
    }

    func singleValueContainer() throws -> any SingleValueDecodingContainer { SingleValue(value: value, codingPath: codingPath) }
}

private struct SingleValue: SingleValueDecodingContainer {
    let value: JSONValue
    let codingPath: [any CodingKey]

    func decodeNil() -> Bool { value == .null }
    func decode(_ type: Bool.Type) throws -> Bool { try JSONValueDecoding.bool(value, codingPath) }
    func decode(_ type: String.Type) throws -> String { try JSONValueDecoding.string(value, codingPath) }
    func decode(_ type: Double.Type) throws -> Double { try JSONValueDecoding.double(value, codingPath) }
    func decode(_ type: Float.Type) throws -> Float { try JSONValueDecoding.float(value, codingPath) }
    func decode(_ type: Int.Type) throws -> Int { try JSONValueDecoding.integer(value, codingPath) }
    func decode(_ type: Int8.Type) throws -> Int8 { try JSONValueDecoding.integer(value, codingPath) }
    func decode(_ type: Int16.Type) throws -> Int16 { try JSONValueDecoding.integer(value, codingPath) }
    func decode(_ type: Int32.Type) throws -> Int32 { try JSONValueDecoding.integer(value, codingPath) }
    func decode(_ type: Int64.Type) throws -> Int64 { try JSONValueDecoding.integer(value, codingPath) }
    func decode(_ type: UInt.Type) throws -> UInt { try JSONValueDecoding.integer(value, codingPath) }
    func decode(_ type: UInt8.Type) throws -> UInt8 { try JSONValueDecoding.integer(value, codingPath) }
    func decode(_ type: UInt16.Type) throws -> UInt16 { try JSONValueDecoding.integer(value, codingPath) }
    func decode(_ type: UInt32.Type) throws -> UInt32 { try JSONValueDecoding.integer(value, codingPath) }
    func decode(_ type: UInt64.Type) throws -> UInt64 { try JSONValueDecoding.integer(value, codingPath) }
    func decode<T: Decodable>(_ type: T.Type) throws -> T { try JSONValueDecoding.unbox(value, as: type, path: codingPath) }
}

private struct KeyedValues<Key: CodingKey>: KeyedDecodingContainerProtocol {
    let object: [String: JSONValue]
    let codingPath: [any CodingKey]

    var allKeys: [Key] { object.keys.compactMap { Key(stringValue: $0) } }

    func contains(_ key: Key) -> Bool { object[key.stringValue] != nil }

    private func value(_ key: Key) throws -> JSONValue {
        guard let value = object[key.stringValue] else {
            throw DecodingError.keyNotFound(key, .init(codingPath: codingPath, debugDescription: "No value associated with key \(key.stringValue)."))
        }
        return value
    }

    private func path(_ key: Key) -> [any CodingKey] { codingPath + [key] }

    func decodeNil(forKey key: Key) throws -> Bool { try value(key) == .null }
    func decode(_ type: Bool.Type, forKey key: Key) throws -> Bool { try JSONValueDecoding.bool(value(key), path(key)) }
    func decode(_ type: String.Type, forKey key: Key) throws -> String { try JSONValueDecoding.string(value(key), path(key)) }
    func decode(_ type: Double.Type, forKey key: Key) throws -> Double { try JSONValueDecoding.double(value(key), path(key)) }
    func decode(_ type: Float.Type, forKey key: Key) throws -> Float { try JSONValueDecoding.float(value(key), path(key)) }
    func decode(_ type: Int.Type, forKey key: Key) throws -> Int { try JSONValueDecoding.integer(value(key), path(key)) }
    func decode(_ type: Int8.Type, forKey key: Key) throws -> Int8 { try JSONValueDecoding.integer(value(key), path(key)) }
    func decode(_ type: Int16.Type, forKey key: Key) throws -> Int16 { try JSONValueDecoding.integer(value(key), path(key)) }
    func decode(_ type: Int32.Type, forKey key: Key) throws -> Int32 { try JSONValueDecoding.integer(value(key), path(key)) }
    func decode(_ type: Int64.Type, forKey key: Key) throws -> Int64 { try JSONValueDecoding.integer(value(key), path(key)) }
    func decode(_ type: UInt.Type, forKey key: Key) throws -> UInt { try JSONValueDecoding.integer(value(key), path(key)) }
    func decode(_ type: UInt8.Type, forKey key: Key) throws -> UInt8 { try JSONValueDecoding.integer(value(key), path(key)) }
    func decode(_ type: UInt16.Type, forKey key: Key) throws -> UInt16 { try JSONValueDecoding.integer(value(key), path(key)) }
    func decode(_ type: UInt32.Type, forKey key: Key) throws -> UInt32 { try JSONValueDecoding.integer(value(key), path(key)) }
    func decode(_ type: UInt64.Type, forKey key: Key) throws -> UInt64 { try JSONValueDecoding.integer(value(key), path(key)) }
    func decode<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T {
        try JSONValueDecoding.unbox(value(key), as: type, path: path(key))
    }

    func nestedContainer<NestedKey: CodingKey>(keyedBy type: NestedKey.Type, forKey key: Key) throws -> KeyedDecodingContainer<NestedKey> {
        try ValueDecoder(value: value(key), codingPath: path(key)).container(keyedBy: type)
    }

    func nestedUnkeyedContainer(forKey key: Key) throws -> any UnkeyedDecodingContainer {
        try ValueDecoder(value: value(key), codingPath: path(key)).unkeyedContainer()
    }

    func superDecoder() throws -> any Decoder {
        ValueDecoder(value: object["super"] ?? .null, codingPath: codingPath)
    }

    func superDecoder(forKey key: Key) throws -> any Decoder {
        ValueDecoder(value: object[key.stringValue] ?? .null, codingPath: path(key))
    }
}

private struct UnkeyedValues: UnkeyedDecodingContainer {
    let array: [JSONValue]
    let codingPath: [any CodingKey]
    private(set) var currentIndex = 0

    init(array: [JSONValue], codingPath: [any CodingKey]) {
        self.array = array
        self.codingPath = codingPath
    }

    var count: Int? { array.count }
    var isAtEnd: Bool { currentIndex >= array.count }

    private mutating func next<T>(_ type: T.Type) throws -> (JSONValue, [any CodingKey]) {
        guard !isAtEnd else {
            throw DecodingError.valueNotFound(type, .init(codingPath: codingPath + [IndexKey(currentIndex)],
                                                          debugDescription: "Unkeyed container is at end."))
        }
        defer { currentIndex += 1 }
        return (array[currentIndex], codingPath + [IndexKey(currentIndex)])
    }

    mutating func decodeNil() throws -> Bool {
        guard !isAtEnd else {
            throw DecodingError.valueNotFound(JSONValue.self, .init(codingPath: codingPath + [IndexKey(currentIndex)],
                                                                    debugDescription: "Unkeyed container is at end."))
        }
        guard array[currentIndex] == .null else { return false }
        currentIndex += 1
        return true
    }

    mutating func decode(_ type: Bool.Type) throws -> Bool { let (v, p) = try next(type); return try JSONValueDecoding.bool(v, p) }
    mutating func decode(_ type: String.Type) throws -> String { let (v, p) = try next(type); return try JSONValueDecoding.string(v, p) }
    mutating func decode(_ type: Double.Type) throws -> Double { let (v, p) = try next(type); return try JSONValueDecoding.double(v, p) }
    mutating func decode(_ type: Float.Type) throws -> Float { let (v, p) = try next(type); return try JSONValueDecoding.float(v, p) }
    mutating func decode(_ type: Int.Type) throws -> Int { let (v, p) = try next(type); return try JSONValueDecoding.integer(v, p) }
    mutating func decode(_ type: Int8.Type) throws -> Int8 { let (v, p) = try next(type); return try JSONValueDecoding.integer(v, p) }
    mutating func decode(_ type: Int16.Type) throws -> Int16 { let (v, p) = try next(type); return try JSONValueDecoding.integer(v, p) }
    mutating func decode(_ type: Int32.Type) throws -> Int32 { let (v, p) = try next(type); return try JSONValueDecoding.integer(v, p) }
    mutating func decode(_ type: Int64.Type) throws -> Int64 { let (v, p) = try next(type); return try JSONValueDecoding.integer(v, p) }
    mutating func decode(_ type: UInt.Type) throws -> UInt { let (v, p) = try next(type); return try JSONValueDecoding.integer(v, p) }
    mutating func decode(_ type: UInt8.Type) throws -> UInt8 { let (v, p) = try next(type); return try JSONValueDecoding.integer(v, p) }
    mutating func decode(_ type: UInt16.Type) throws -> UInt16 { let (v, p) = try next(type); return try JSONValueDecoding.integer(v, p) }
    mutating func decode(_ type: UInt32.Type) throws -> UInt32 { let (v, p) = try next(type); return try JSONValueDecoding.integer(v, p) }
    mutating func decode(_ type: UInt64.Type) throws -> UInt64 { let (v, p) = try next(type); return try JSONValueDecoding.integer(v, p) }
    mutating func decode<T: Decodable>(_ type: T.Type) throws -> T {
        let (v, p) = try next(type)
        return try JSONValueDecoding.unbox(v, as: type, path: p)
    }

    mutating func nestedContainer<NestedKey: CodingKey>(keyedBy type: NestedKey.Type) throws -> KeyedDecodingContainer<NestedKey> {
        let (v, p) = try next(KeyedDecodingContainer<NestedKey>.self)
        return try ValueDecoder(value: v, codingPath: p).container(keyedBy: type)
    }

    mutating func nestedUnkeyedContainer() throws -> any UnkeyedDecodingContainer {
        let (v, p) = try next((any UnkeyedDecodingContainer).self)
        return try ValueDecoder(value: v, codingPath: p).unkeyedContainer()
    }

    mutating func superDecoder() throws -> any Decoder {
        let (v, p) = try next((any Decoder).self)
        return ValueDecoder(value: v, codingPath: p)
    }
}

extension JSONValue {
    /// The JSON text `data` parsed by `JSONSerialization` (nil when it refuses it): the value
    /// `JSONDecoder().decode(JSONValue.self, from: data)` gives, without `JSONValue`'s
    /// `Decodable` trying each JSON type in turn, a thrown error per miss, at every value.
    public init?(jsonData data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              let value = JSONValue(foundation: object) else { return nil }
        self = value
    }

    /// A `JSONSerialization` value as a `JSONValue` (nil for anything JSON does not hold).
    init?(foundation object: Any) {
        switch object {
        case is NSNull:
            self = .null
        case let string as String:
            self = .string(string)
        case let number as NSNumber:
            // A JSON true or false is a CFBoolean; every other number is a number.
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else {
                self = .number(number.doubleValue)
            }
        case let array as [Any]:
            var values: [JSONValue] = []
            values.reserveCapacity(array.count)
            for element in array {
                guard let value = JSONValue(foundation: element) else { return nil }
                values.append(value)
            }
            self = .array(values)
        case let dictionary as [String: Any]:
            var values: [String: JSONValue] = [:]
            values.reserveCapacity(dictionary.count)
            for (key, element) in dictionary {
                guard let value = JSONValue(foundation: element) else { return nil }
                values[key] = value
            }
            self = .object(values)
        default:
            return nil
        }
    }
}
