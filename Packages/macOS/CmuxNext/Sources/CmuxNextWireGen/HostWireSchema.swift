import Foundation

// The schema side of HostWireEmitter: chromium-host-wire.json's shape, its integers and its errors.

/// Why cmux-tui/spec/chromium-host-wire.json cannot be built into Swift, with its JSON path.
struct HostWireSchemaError: Error, Equatable, CustomStringConvertible {
    let path: String
    let message: String

    var description: String { "chromium-host-wire.json: \(path): \(message)" }
}

extension HostWireEmitter {
    /// One fixed-width integer type of the schema (`u8` ... `i64`).
    struct IntegerType: Equatable {
        let bytes: Int
        let signed: Bool

        static let names: [String: IntegerType] = [
            "u8": .init(bytes: 1, signed: false), "u16": .init(bytes: 2, signed: false),
            "u32": .init(bytes: 4, signed: false), "u64": .init(bytes: 8, signed: false),
            "i8": .init(bytes: 1, signed: true), "i16": .init(bytes: 2, signed: true),
            "i32": .init(bytes: 4, signed: true), "i64": .init(bytes: 8, signed: true),
        ]

        var swift: String { (signed ? "Int" : "UInt") + "\(8 * bytes)" }
        var unsignedSwift: String { "UInt\(8 * bytes)" }

        /// Whether `value` fits.
        func holds(_ value: WireInteger) -> Bool {
            let bits = UInt64(8 * bytes)
            if !signed { return !value.negative && (bits == 64 || value.magnitude >> bits == 0) }
            let limit = UInt64(1) << (bits - 1)
            return value.negative ? value.magnitude <= limit : value.magnitude < limit
        }
    }

    /// A schema integer: a JSON number, or a "0x" string for one a JSON number cannot hold exactly.
    struct WireInteger: Decodable, Equatable {
        let negative: Bool
        let magnitude: UInt64

        init(negative: Bool, magnitude: UInt64) {
            self.negative = negative && magnitude != 0
            self.magnitude = magnitude
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let text = try? container.decode(String.self) {
                guard text.hasPrefix("0x"), let value = UInt64(text.dropFirst(2), radix: 16) else {
                    throw DecodingError.dataCorruptedError(in: container, debugDescription: "\(text) is not a 0x hex string")
                }
                self.init(negative: false, magnitude: value)
            } else if let value = try? container.decode(Int64.self) {
                self.init(negative: value < 0, magnitude: value.magnitude)
            } else {
                self.init(negative: false, magnitude: try container.decode(UInt64.self))
            }
        }

        /// The Swift literal: hex above 0xffff, decimal otherwise.
        var literal: String {
            if negative { return "-\(magnitude)" }
            return magnitude > 0xFFFF ? "0x" + String(magnitude, radix: 16) : "\(magnitude)"
        }
    }
}

/// chromium-host-wire.json as HostWireEmitter reads it; `golden` and `cpp` are the tests' and the C++ side's.
struct HostWireDocument: Decodable {
    struct SwiftSection: Decodable {
        let type: String
        let condition: String?
    }

    struct Header: Decodable {
        let size: Int
        let fields: [FieldEntry]
    }

    struct FieldEntry: Decodable {
        let name: String
        let type: String
        let count: Int?
        let role: String?
        let doc: [String]?
    }

    struct ConstantEntry: Decodable {
        let name: String
        let type: String
        let value: HostWireEmitter.WireInteger
        let doc: [String]?
    }

    struct KindEntry: Decodable {
        let name: String
        let value: UInt32
        let direction: String
        let doc: [String]?
    }

    let version: Int
    let byteOrder: String
    let swift: SwiftSection
    let header: Header
    let maxPayload: UInt32
    let constants: [ConstantEntry]
    let kinds: [KindEntry]

    enum CodingKeys: String, CodingKey {
        case version, swift, header, constants, kinds
        case byteOrder = "byte_order"
        case maxPayload = "max_payload"
    }
}
