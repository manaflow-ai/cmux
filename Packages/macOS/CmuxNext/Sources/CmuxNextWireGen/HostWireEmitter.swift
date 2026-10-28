import Foundation

/// Writes the Swift side of the wire between cmux and the Chromium host app (task p05-ipc-181):
/// the frame struct of chromium-host-wire.json's `swift.type` (`ChromiumHostFrame`) with its
/// stored header fields, `Kind`, the wire constants, `encoded()` and `decode(_:)`. The C++ side
/// of the same schema is cmux-tui/bindings/codegen/host_wire_cpp.py, which refuses the
/// same schemas (host_wire.py) and also checks the golden frames; ChromiumHostFrameTests checks
/// this codec against them. The helpers that read a kind's fields stay hand-written in an
/// extension (CmuxNextBrowser's ChromiumHostFrame.swift).
///
/// main writes `source()` for `--host-wire-output`; CmuxNextWireGenPlugin runs it for
/// CmuxNextBrowser with the schema as its only input, so only a schema or generator edit
/// rebuilds it, and nothing it writes is in git.
struct HostWireEmitter {
    /// The file the plugin has main write `source()` to.
    static let outputFileName = "ChromiumHostFrame+Wire.swift"

    enum Role: String, Equatable {
        case kind
        case payloadLength = "payload_length"
    }

    /// One header field, at its byte offset.
    struct Field: Equatable {
        let name: String
        let type: IntegerType
        let count: Int
        let role: Role?
        let offset: Int
        let doc: [String]
    }

    struct Constant: Equatable {
        let name: String
        let type: IntegerType
        let value: WireInteger
        let doc: [String]
    }

    struct Kind: Equatable {
        let name: String
        let value: UInt32
        let toHost: Bool
        let doc: [String]
    }

    let typeName: String
    let condition: String?
    let headerSize: Int
    let maxPayload: UInt32
    let fields: [Field]
    let constants: [Constant]
    let kinds: [Kind]

    /// Names the emitted struct declares itself; no field or constant may take one.
    static let memberNames: Set<String> = [
        "rawKind", "payload", "kind", "headerSize", "maxPayload", "encoded", "decode", "init",
    ]
    /// Swift and C++ keywords; both sides use a field's name as written (host_wire.py's KEYWORDS).
    static let keywords: Set<String> = Set("""
        alignas alignof and asm associatedtype auto bool break case catch char class const constexpr
        continue default defer delete deinit do double else enum explicit export extension extern
        fallthrough false fileprivate float for friend func goto guard if import in init inline int
        internal is let long mutable namespace new nil not nullptr operator or private protocol
        public register repeat return self short signed sizeof static struct subscript super switch
        template this throw throws true try typedef typename union unsigned using var virtual void
        volatile where while
        """.split(whereSeparator: \.isWhitespace).map(String.init))

    init(schema: Data) throws(HostWireSchemaError) {
        let document: HostWireDocument
        do {
            document = try JSONDecoder().decode(HostWireDocument.self, from: schema)
        } catch {
            throw HostWireSchemaError(path: "$", message: "not a host wire schema: \(error)")
        }
        guard document.version == 1 else { throw HostWireSchemaError(path: "$.version", message: "only version 1 is known") }
        guard document.byteOrder == "little" else {
            throw HostWireSchemaError(path: "$.byte_order", message: "only little is known")
        }
        guard Self.isTypeName(document.swift.type) else {
            throw HostWireSchemaError(path: "$.swift.type", message: "\(document.swift.type) is not an UpperCamelCase type name")
        }
        typeName = document.swift.type
        condition = document.swift.condition
        headerSize = document.header.size
        maxPayload = document.maxPayload

        var names = Self.memberNames
        var fields: [Field] = []
        var offset = 0
        for (index, entry) in document.header.fields.enumerated() {
            let path = "$.header.fields[\(index)]"
            let type = try Self.integerType(entry.type, path: path + ".type")
            let count = entry.count ?? 1
            guard count >= 1 else { throw HostWireSchemaError(path: path + ".count", message: "must be positive") }
            var role: Role?
            if let raw = entry.role {
                guard let known = Role(rawValue: raw) else {
                    throw HostWireSchemaError(path: path + ".role", message: "\(raw) is not kind or payload_length")
                }
                role = known
            }
            // The kind and payload length are `rawKind` and `payload.count`, not stored fields by their names.
            if role == nil { try Self.claim(entry.name, path: path + ".name", in: &names) }
            guard offset % type.bytes == 0 else {
                throw HostWireSchemaError(path: path, message: "\(entry.name) at byte \(offset) is not \(type.bytes)-byte aligned")
            }
            fields.append(Field(name: entry.name, type: type, count: count, role: role, offset: offset, doc: entry.doc ?? []))
            offset += type.bytes * count
        }
        guard offset == headerSize else {
            throw HostWireSchemaError(path: "$.header", message: "the fields fill \(offset) bytes, not size \(headerSize)")
        }
        for role in [Role.kind, .payloadLength] {
            let holders = fields.filter { $0.role == role }
            guard holders.count == 1, holders[0].type == IntegerType(bytes: 4, signed: false), holders[0].count == 1 else {
                throw HostWireSchemaError(path: "$.header.fields", message: "needs exactly one u32 field with role \(role.rawValue)")
            }
        }
        self.fields = fields

        var constants: [Constant] = []
        for (index, entry) in document.constants.enumerated() {
            let path = "$.constants[\(index)]"
            try Self.claim(entry.name, path: path + ".name", in: &names)
            let type = try Self.integerType(entry.type, path: path + ".type")
            guard type.holds(entry.value) else {
                throw HostWireSchemaError(path: path + ".value", message: "\(entry.value.literal) does not fit \(entry.type)")
            }
            constants.append(Constant(name: entry.name, type: type, value: entry.value, doc: entry.doc ?? []))
        }
        self.constants = constants

        var kindNames: Set<String> = []
        var values: Set<UInt32> = []
        var kinds: [Kind] = []
        for (index, entry) in document.kinds.enumerated() {
            let path = "$.kinds[\(index)]"
            try Self.claim(entry.name, path: path + ".name", in: &kindNames)
            guard entry.value != 0, values.insert(entry.value).inserted else {
                throw HostWireSchemaError(path: path + ".value", message: "\(entry.value) is 0 or taken")
            }
            guard entry.direction == "to_host" || entry.direction == "to_cmux" else {
                throw HostWireSchemaError(path: path + ".direction", message: "must be to_host or to_cmux")
            }
            kinds.append(Kind(name: entry.name, value: entry.value, toHost: entry.direction == "to_host", doc: entry.doc ?? []))
        }
        self.kinds = kinds
        guard !kinds.isEmpty else { throw HostWireSchemaError(path: "$.kinds", message: "must not be empty") }
    }

    private static func integerType(_ name: String, path: String) throws(HostWireSchemaError) -> IntegerType {
        guard let type = IntegerType.names[name] else {
            throw HostWireSchemaError(path: path, message: "\(name) is not an integer type")
        }
        return type
    }

    /// Takes `name` for one member, refusing a name that is no lowerCamelCase identifier, a keyword or taken.
    private static func claim(_ name: String, path: String, in names: inout Set<String>) throws(HostWireSchemaError) {
        guard let first = name.unicodeScalars.first, (0x61...0x7A).contains(first.value),
              name.unicodeScalars.allSatisfy(isIdentifierScalar)
        else {
            throw HostWireSchemaError(path: path, message: "\(name) is not a lowerCamelCase name")
        }
        guard !keywords.contains(name) else { throw HostWireSchemaError(path: path, message: "\(name) is a keyword") }
        guard names.insert(name).inserted else { throw HostWireSchemaError(path: path, message: "\(name) is taken") }
    }

    private static func isTypeName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, (0x41...0x5A).contains(first.value) else { return false }
        return name.unicodeScalars.allSatisfy(isIdentifierScalar)
    }

    /// An ASCII letter or digit.
    private static func isIdentifierScalar(_ scalar: Unicode.Scalar) -> Bool {
        (0x30...0x39).contains(scalar.value) || (0x41...0x5A).contains(scalar.value) || (0x61...0x7A).contains(scalar.value)
    }

    /// The Swift source, the same bytes every run.
    func source() -> String {
        var out: [String] = [
            "// Built by CmuxNextWireGen (HostWireEmitter) from cmux-tui/spec/chromium-host-wire.json at build",
            "// time; not in git (task p05-ipc-181). Change the schema, not this file.",
            "",
        ]
        if let condition { out.append("#if \(condition)") }
        out += [
            "/// One frame of the wire between cmux and the Chromium host app: a \(headerSize)-byte little-endian",
            "/// header and `payload` bytes after it. The C++ side is ChromiumHost/src/chromium_host_wire.h, built",
            "/// from the same schema; the helpers that read a kind's fields are in \(typeName).swift.",
            "nonisolated struct \(typeName): Equatable, Sendable {",
            "    enum Kind: UInt32, Sendable {",
        ]
        var toHost: Bool?
        for kind in kinds {
            if kind.toHost != toHost {
                toHost = kind.toHost
                out.append(kind.toHost ? "        // cmux -> host" : "        // host -> cmux")
            }
            out += Self.docLines(kind.doc, indent: "        ")
            out.append("        case \(kind.name) = \(kind.value)")
        }
        out += [
            "    }",
            "",
            "    /// The header every frame starts with, in bytes.",
            "    static let headerSize = \(headerSize)",
            "    /// Longer payloads end the connection.",
            "    static let maxPayload = \(maxPayload)",
        ]
        for constant in constants {
            out += Self.docLines(constant.doc, indent: "    ")
            out.append("    static let \(constant.name): \(constant.type.swift) = \(constant.value.literal)")
        }
        out.append("")
        for field in fields where field.role != .payloadLength {
            out += Self.docLines(field.doc, indent: "    ")
            if field.role == .kind {
                out.append("    var rawKind: \(field.type.swift)")
            } else if field.count > 1 {
                let zeros = Array(repeating: "0", count: field.count).joined(separator: ", ")
                out.append("    var \(field.name): [\(field.type.swift)] = [\(zeros)]")
            } else {
                out.append("    var \(field.name): \(field.type.swift) = 0")
            }
        }
        out += [
            "    /// The bytes after the header.",
            "    var payload: [UInt8] = []",
            "",
            "    init(rawKind: UInt32) { self.rawKind = rawKind }",
            "",
            "    /// The header and payload as sent. An array field shorter than its count sends zeros for the rest.",
            "    func encoded() -> [UInt8] {",
            "        var bytes = [UInt8]()",
            "        bytes.reserveCapacity(Self.headerSize + payload.count)",
            "        func put<T: FixedWidthInteger>(_ value: T) {",
            "            for shift in stride(from: 0, to: T.bitWidth, by: 8) {",
            "                bytes.append(UInt8(truncatingIfNeeded: value >> shift))",
            "            }",
            "        }",
        ]
        out += fields.map(encodeLine)
        out += [
            "        bytes.append(contentsOf: payload)",
            "        return bytes",
            "    }",
            "",
            "    enum Decoded: Equatable, Sendable {",
            "        /// A whole frame, and how many bytes of the input it took.",
            "        case frame(\(typeName), consumed: Int)",
            "        /// The input ends inside a frame.",
            "        case needMore",
            "        /// The header announces a payload over ``maxPayload``: the stream is broken.",
            "        case invalid",
            "    }",
            "",
            "    /// Decodes the first frame of `bytes`.",
            "    static func decode(_ bytes: ArraySlice<UInt8>) -> Decoded {",
            "        guard bytes.count >= headerSize else { return .needMore }",
            "        let base = bytes.startIndex",
            "        func get<T: FixedWidthInteger>(_ offset: Int, _: T.Type) -> T {",
            "            var value: T = 0",
            "            for index in 0..<MemoryLayout<T>.size {",
            "                value |= T(bytes[base + offset + index]) << (8 * index)",
            "            }",
            "            return value",
            "        }",
        ]
        if let length = fields.first(where: { $0.role == .payloadLength }),
           let kind = fields.first(where: { $0.role == .kind }) {
            out += [
                "        let length = Int(get(\(length.offset), UInt32.self))",
                "        guard length <= maxPayload else { return .invalid }",
                "        guard bytes.count >= headerSize + length else { return .needMore }",
                "        var frame = \(typeName)(rawKind: get(\(kind.offset), UInt32.self))",
            ]
        }
        out += fields.compactMap(decodeLine)
        out += [
            "        frame.payload = Array(bytes[(base + headerSize)..<(base + headerSize + length)])",
            "        return .frame(frame, consumed: headerSize + length)",
            "    }",
            "}",
        ]
        if condition != nil { out.append("#endif") }
        return out.joined(separator: "\n") + "\n"
    }

    private func encodeLine(_ field: Field) -> String {
        switch field.role {
        case .kind: return "        put(rawKind)"
        case .payloadLength: return "        put(UInt32(payload.count))"
        case nil: break
        }
        let unsigned = field.type.unsignedSwift
        if field.count > 1 {
            let element = "index < \(field.name).count ? \(field.name)[index] : 0"
            let value = field.type.signed ? "\(unsigned)(bitPattern: \(element))" : element
            return "        for index in 0..<\(field.count) { put(\(value)) }"
        }
        return "        put(\(field.type.signed ? "\(unsigned)(bitPattern: \(field.name))" : field.name))"
    }

    private func decodeLine(_ field: Field) -> String? {
        guard field.role == nil else { return nil }
        let unsigned = field.type.unsignedSwift
        if field.count > 1 {
            let read = "get(\(field.offset) + \(field.type.bytes) * $0, \(unsigned).self)"
            let value = field.type.signed ? "\(field.type.swift)(bitPattern: \(read))" : read
            return "        frame.\(field.name) = (0..<\(field.count)).map { \(value) }"
        }
        let read = "get(\(field.offset), \(unsigned).self)"
        return "        frame.\(field.name) = \(field.type.signed ? "\(field.type.swift)(bitPattern: \(read))" : read)"
    }

    private static func docLines(_ lines: [String], indent: String) -> [String] {
        lines.map { "\(indent)/// \($0)".replacingOccurrences(of: "\n", with: " ") }
    }
}
