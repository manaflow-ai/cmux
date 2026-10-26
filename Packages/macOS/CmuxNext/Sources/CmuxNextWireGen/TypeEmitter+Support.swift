// TypeEmitter's support file (p05-ipc-020): the typed ids, the opaque JSON
// value and the decoding helpers every generated file uses.

/// A typed id of the naming map: a member with one of `members` as its wire
/// name and `scalar` as its type is this id, not a bare integer or string, so a
/// pane id cannot be passed where a surface id is expected. The names are the
/// app's (CmuxNextDaemon/Wire/Handles.swift and StringIDs.swift).
struct WireIDType: Equatable {
    let name: String
    let scalar: TypeSchema.Scalar
    let members: Set<String>
    let summary: String

    static let all: [WireIDType] = [
        WireIDType(name: "WorkspaceHandle", scalar: .uint64, members: ["workspace"],
                   summary: "A workspace's numeric handle, valid for one daemon generation."),
        WireIDType(name: "ScreenID", scalar: .uint64, members: ["screen", "screens"],
                   summary: "A screen's numeric handle, valid for one daemon generation."),
        WireIDType(name: "PaneID", scalar: .uint64, members: ["pane", "panes", "active_pane", "zoomed_pane"],
                   summary: "A pane's numeric handle, valid for one daemon generation."),
        WireIDType(name: "SurfaceID", scalar: .uint64, members: ["surface", "surfaces"],
                   summary: "A tab's numeric handle (the protocol's `surface`), valid for one daemon generation."),
        WireIDType(name: "SplitID", scalar: .uint64, members: ["split"],
                   summary: "A split node's numeric handle, stable while the split exists."),
        WireIDType(name: "ClientID", scalar: .uint64, members: ["client"],
                   summary: "A connected client's numeric handle."),
        WireIDType(name: "NotificationID", scalar: .uint64, members: ["notification"],
                   summary: "A notification's numeric handle."),
        WireIDType(name: "TerminalID", scalar: .string, members: ["terminal_id", "terminal_ids"],
                   summary: "A terminal's durable id (32 hex characters): it survives restarts and moves."),
    ]

    /// The id the member `member` of type `scalar` holds, if the map names one.
    static func forMember(_ member: String?, scalar: TypeSchema.Scalar) -> WireIDType? {
        guard let member else { return nil }
        return all.first { $0.scalar == scalar && $0.members.contains(member) }
    }

    func declaration() -> String {
        let raw = scalar.swiftName
        let literal = scalar == .string ? "ExpressibleByStringLiteral" : "ExpressibleByIntegerLiteral"
        let literalInit = scalar == .string
            ? "public init(stringLiteral value: String) { self.init(rawValue: value) }"
            : "public init(integerLiteral value: UInt64) { self.init(rawValue: value) }"
        return """

        /// \(summary)
        public struct \(name): RawRepresentable, Codable, Sendable, Hashable, Comparable, CustomStringConvertible, \(literal) {
            public let rawValue: \(raw)

            public init(rawValue: \(raw)) { self.rawValue = rawValue }
            \(literalInit)

            public init(from decoder: any Decoder) throws {
                self.init(rawValue: try decoder.singleValueContainer().decode(\(raw).self))
            }

            public func encode(to encoder: any Encoder) throws {
                var container = encoder.singleValueContainer()
                try container.encode(rawValue)
            }

            public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
            public var description: String { String(rawValue) }
        }

        """
    }
}

extension TypeEmitter {
    /// The support file's source: the same bytes for every schema.
    static func supportSource() -> String {
        var out = header("Typed ids, opaque JSON and the decoding helpers of the generated types")
        for id in WireIDType.all {
            out += id.declaration()
        }
        out += """

        /// A JSON value the schema leaves open (`opaque_json`), or a variant this
        /// build does not know. Integers stay integers, so ids round-trip exactly.
        public enum \(wireJSON): Codable, Sendable, Equatable {
            case null
            case bool(Bool)
            case integer(Int64)
            case unsignedInteger(UInt64)
            case number(Double)
            case string(String)
            case array([\(wireJSON)])
            case object([String: \(wireJSON)])

            public init(from decoder: any Decoder) throws {
                let container = try decoder.singleValueContainer()
                if container.decodeNil() {
                    self = .null
                } else if let value = try? container.decode(Bool.self) {
                    self = .bool(value)
                } else if let value = try? container.decode(Int64.self) {
                    self = .integer(value)
                } else if let value = try? container.decode(UInt64.self) {
                    self = .unsignedInteger(value)
                } else if let value = try? container.decode(Double.self) {
                    self = .number(value)
                } else if let value = try? container.decode(String.self) {
                    self = .string(value)
                } else if let value = try? container.decode([\(wireJSON)].self) {
                    self = .array(value)
                } else {
                    self = .object(try container.decode([String: \(wireJSON)].self))
                }
            }

            public func encode(to encoder: any Encoder) throws {
                var container = encoder.singleValueContainer()
                switch self {
                case .null: try container.encodeNil()
                case .bool(let value): try container.encode(value)
                case .integer(let value): try container.encode(value)
                case .unsignedInteger(let value): try container.encode(value)
                case .number(let value): try container.encode(value)
                case .string(let value): try container.encode(value)
                case .array(let value): try container.encode(value)
                case .object(let value): try container.encode(value)
                }
            }
        }

        /// The keys of an object type with no members: it still decodes only an
        /// object and encodes as `{}`.
        struct \(anyKey): CodingKey {
            let stringValue: String
            let intValue: Int?

            init?(stringValue: String) {
                self.stringValue = stringValue
                intValue = nil
            }

            init?(intValue: Int) {
                stringValue = String(intValue)
                self.intValue = intValue
            }
        }

        extension KeyedDecodingContainer {
            /// The first of a member's wire names (its name, then its aliases) that is present.
            func wireKey(_ first: Key, _ aliases: Key...) -> Key {
                aliases.first { !contains(first) && contains($0) } ?? first
            }

            /// Checks a literal member: present (or `required`) means equal to `constant`.
            func wireLiteral<Value: Decodable & Equatable & Sendable>(
                _ constant: Value,
                forKey key: Key,
                required: Bool
            ) throws {
                guard required || contains(key) else { return }
                let value = try decode(Value.self, forKey: key)
                guard value == constant else {
                    throw DecodingError.dataCorruptedError(
                        forKey: key, in: self, debugDescription: "expected \\(constant), got \\(value)")
                }
            }
        }

        """
        return out
    }
}
