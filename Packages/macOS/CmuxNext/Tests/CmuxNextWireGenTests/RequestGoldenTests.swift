import Foundation
import Testing
@testable import CmuxNextWireGen

/// What a test gives one member of an emitted request: the JSON its Swift value encodes
/// as. A `FieldUpdate` member takes `.unchanged`, `.clear` or `.set`; an optional takes
/// `.unchanged` (nil) or `.set`.
private enum MemberValue {
    case unchanged
    case clear
    case set(SchemaJSON)
}

/// The coder RequestEmitter wrote for one request, read back from its Swift source: the
/// request's own CodingKeys (raw values), stored properties and `encode(to:)` statements.
/// The line it builds takes every key from the emitted `forKey:` case and that case's raw
/// value, so a wrong raw value, case or property name shows in the line. It does not run
/// the Swift: how a value encodes (`SurfaceID` as a number, `Data` as base64) is the
/// caller's `SchemaJSON` until task 025 compiles the generated types next to
/// `WireCoding.encodeRequest` for a real round trip.
private struct EmittedRequestCoder {
    /// The request's members sit one level in; its nested types' members two.
    private static let member = "    "
    private static let statement = "        "

    private(set) var keys: [String: String] = [:]
    private(set) var properties: [String: String] = [:]
    private(set) var statements: [String] = []

    init(source: String) {
        var block = ""
        for line in source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if line == Self.member + "}" {
                block = ""
            } else if line == Self.member + "enum CodingKeys: String, CodingKey {" {
                block = "keys"
            } else if line == Self.member + "public func encode(to encoder: any Encoder) throws {" {
                block = "encode"
            } else if block.isEmpty, let declaration = Self.after(line, Self.member + "public var ") {
                let parts = declaration.components(separatedBy: ": ")
                properties[parts[0]] = parts.dropFirst().joined(separator: ": ")
            } else if block == "keys", let entry = Self.after(line, Self.statement + "case ") {
                let parts = entry.components(separatedBy: " = ")
                keys[parts[0]] = parts.count == 2 ? String(parts[1].dropFirst().dropLast()) : parts[0]
            } else if block == "encode", let body = Self.after(line, Self.statement) {
                statements.append(body)
            }
        }
    }

    /// The `{id, cmd, ...}` line for `values` (Swift property name -> value).
    func line(id: Int64, command: String, values: [String: MemberValue]) -> SchemaJSON {
        var fields: [String: SchemaJSON] = ["id": .integer(id), "cmd": .string(command)]
        var used: Set<String> = []
        var index = statements.startIndex
        while index < statements.endIndex {
            let statement = statements[index]
            index += 1
            if statement.hasPrefix("var container = ") { continue }
            if let call = Self.inside(statement, "try container.encodeIfPresent(self.", ")") {
                let (name, key) = resolve(call)
                used.insert(name)
                switch values[name] ?? .unchanged {
                case .unchanged: break
                case .clear: Issue.record("\(name) is optional: nil leaves it out, it cannot be null")
                case .set(let value): fields[key] = value
                }
            } else if let call = Self.inside(statement, "try container.encode(self.", ")") {
                let (name, key) = resolve(call)
                used.insert(name)
                switch values[name] {
                case .set(let value)?: fields[key] = value
                case .clear?: fields[key] = .null
                case .unchanged?, nil: Issue.record("\(name) is required")
                }
            } else if let name = Self.inside(statement, "switch self.", " {") {
                let arms = statements[index..<min(index + 4, statements.endIndex)].map { $0 }
                index += arms.count
                used.insert(name)
                guard arms.count == 4, arms[0] == "case .unchanged: break", arms[3] == "}",
                      let clear = Self.inside(arms[1], "case .clear: try container.encodeNil(forKey: .", ")"),
                      let assigned = Self.inside(arms[2], "case .set(let value): try container.encode(value, forKey: .", ")"),
                      clear == assigned, let key = keys[clear] else {
                    Issue.record("not a FieldUpdate switch: \(arms)")
                    continue
                }
                switch values[name] ?? .unchanged {
                case .unchanged: break
                case .clear: fields[key] = .null
                case .set(let value): fields[key] = value
                }
            } else if let call = Self.inside(statement, "try container.encode(", ")") {
                let parts = call.components(separatedBy: ", forKey: .")
                let constant = parts[0].components(separatedBy: " as ")[0]
                guard parts.count == 2, let key = keys[parts[1]],
                      let value = try? JSONDecoder().decode(SchemaJSON.self, from: Data(constant.utf8)) else {
                    Issue.record("not a constant: \(statement)")
                    continue
                }
                fields[key] = value
            } else {
                Issue.record("unknown statement: \(statement)")
            }
        }
        for name in values.keys where !used.contains(name) { Issue.record("no member writes \(name)") }
        return .object(fields)
    }

    /// `name, forKey: .key` -> the property and its key's raw value.
    private func resolve(_ call: String) -> (name: String, key: String) {
        let parts = call.components(separatedBy: ", forKey: .")
        guard parts.count == 2, properties[parts[0]] != nil, let key = keys[parts[1]] else {
            Issue.record("no property or key: \(call)")
            return (name: parts[0], key: "?")
        }
        return (name: parts[0], key: key)
    }

    private static func after(_ line: String, _ prefix: String) -> String? {
        line.hasPrefix(prefix) ? String(line.dropFirst(prefix.count)) : nil
    }

    private static func inside(_ line: String, _ prefix: String, _ suffix: String) -> String? {
        guard line.hasPrefix(prefix), line.hasSuffix(suffix), line.count >= prefix.count + suffix.count else {
            return nil
        }
        return String(line.dropFirst(prefix.count).dropLast(suffix.count))
    }
}

private func json(_ text: String) throws -> SchemaJSON {
    try JSONDecoder().decode(SchemaJSON.self, from: Data(text.utf8))
}

/// Golden lines of RequestEmitter's requests (p05-ipc task 021), built from the emitted
/// CodingKeys and `encode(to:)`, against the lines the hand-written requests send.
@Suite struct RequestGoldenTests {
    private static func emitted(_ wire: String) throws -> String {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 { root.deleteLastPathComponent() }
        let data = try Data(contentsOf: root.appendingPathComponent("cmux-tui/spec/sdk-schema.json"))
        let schema = try RequestSchema(sdkSchema: data)
        let command = try #require(schema.commands.first { $0.wire == wire })
        return RequestEmitter(schema: schema).source(for: command)
    }

    /// The keys and omissions of CmuxNextDaemonTests/SendInputRequestTests' lines. Their
    /// value encodings wait for task 025's round trip through `WireCoding.encodeRequest`.
    @Test func sendInputsEmittedKeysGiveTheHandWrittenLines() throws {
        let source = try Self.emitted("send")
        let coder = EmittedRequestCoder(source: source)
        #expect(coder.properties["surface"] == "FieldUpdate<SurfaceID>")
        #expect(coder.properties["bytes"] == "FieldUpdate<Data>")
        #expect(coder.properties["flow"] == "FieldUpdate<UInt64>")
        #expect(coder.properties["paste"] == "Bool?")
        #expect(coder.properties["stream"] == "UInt16?")
        #expect(coder.keys.count == coder.properties.count)

        let guarded = coder.line(id: 3, command: "send", values: [
            "surface": .set(.integer(7)), "text": .set(.string("yes")), "paste": .set(.bool(true)),
            "expectForeground": .set(.string("/usr/local/bin/claude")),
        ])
        #expect(try guarded == json(#"""
            {"id": 3, "cmd": "send", "surface": 7, "text": "yes", "paste": true,
             "expect_foreground": "/usr/local/bin/claude"}
            """#))
        let flow: Int64 = (4242 << 32) | 7
        let traced = coder.line(id: 5, command: "send", values: [
            "surface": .set(.integer(7)), "bytes": .set(.string("YQ==")), "flow": .set(.integer(flow)),
        ])
        #expect(try traced == json(#"{"id": 5, "cmd": "send", "surface": 7, "bytes": "YQ==", "flow": \#(flow)}"#))
        let plain = coder.line(id: 4, command: "send", values: ["surface": .set(.integer(7)), "text": .set(.string("\r"))])
        #expect(try plain == json(#"{"cmd": "send", "id": 4, "text": "\r", "surface": 7}"#))
        let streamed = coder.line(id: 6, command: "send", values: [
            "terminalID": .set(.string("t1")), "bytes": .set(.string("YQ==")), "stream": .set(.integer(2)),
        ])
        #expect(try streamed == json(#"{"id": 6, "cmd": "send", "terminal_id": "t1", "bytes": "YQ==", "stream": 2}"#))
    }

    /// update-bookmark: "null clears" the icon, absent leaves it, as the hand-written
    /// request's `FieldUpdate` members send.
    @Test func anOptionalNullableMemberSendsNullToClear() throws {
        let source = try Self.emitted("update-bookmark")
        #expect(source.contains("icon: FieldUpdate<String> = .unchanged"))
        let coder = EmittedRequestCoder(source: source)
        let cleared = coder.line(id: 1, command: "update-bookmark", values: [
            "bookmark": .set(.string("b1")), "icon": .clear, "title": .set(.string("Docs")),
        ])
        #expect(try cleared == json(#"{"id": 1, "cmd": "update-bookmark", "bookmark": "b1", "icon": null, "title": "Docs"}"#))
        let untouched = coder.line(id: 2, command: "update-bookmark", values: ["bookmark": .set(.string("b1"))])
        #expect(try untouched == json(#"{"id": 2, "cmd": "update-bookmark", "bookmark": "b1"}"#))
    }
}
