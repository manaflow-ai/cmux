// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Helper wire protocol v1: UTF-8 JSON, one object per line, on the helper
/// socket and on the host control pipe.
enum HelperWire {
    static let protocolVersion = 1
    static let maxLineBytes = 8 << 20

    /// Splits a byte stream into lines.
    struct LineBuffer {
        private var pending = Data()
        init() {}

        /// Appends bytes; returns complete lines (without "\n"), or nil when a line is too long.
        mutating func append(_ bytes: Data) -> [Data]? {
            pending.append(bytes)
            var lines: [Data] = []
            while let newline = pending.firstIndex(of: 0x0A) {
                lines.append(pending[pending.startIndex..<newline])
                pending.removeSubrange(pending.startIndex...newline)
            }
            return pending.count > maxLineBytes ? nil : lines
        }
    }

    static func object(_ line: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
    }

    /// Encodes `fields` plus `raw` JSON values (already-encoded results) as one line.
    static func line(_ fields: [String: Any], raw: [String: Data] = [:]) -> Data {
        var body = (try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])) ?? Data("{}".utf8)
        if !raw.isEmpty {
            body.removeLast() // "}"
            for (key, value) in raw.sorted(by: { $0.key < $1.key }) {
                if body.count > 1 { body.append(Data(",".utf8)) }
                body.append((try? JSONSerialization.data(withJSONObject: key, options: [.fragmentsAllowed])) ?? Data())
                body.append(Data(":".utf8))
                body.append(value)
            }
            body.append(Data("}".utf8))
        }
        body.append(0x0A)
        return body
    }

    static func json(_ value: Any) -> Data {
        (try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys])) ?? Data("null".utf8)
    }

    static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

    static func unhex(_ text: String) -> Data? {
        guard text.count % 2 == 0 else { return nil }
        var data = Data(capacity: text.count / 2)
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(index, offsetBy: 2)
            guard let byte = UInt8(text[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        return data
    }
}

/// The tools behind the socket: upstream Cua Driver in production, a fake in tests.
public protocol ToolInvoking: Sendable {
    func listTools() async throws -> Data
    func invoke(name: String, arguments: Data) async throws -> Data
}

public struct ToolError: Error, Sendable, CustomStringConvertible {
    public var description: String
    public init(_ description: String) { self.description = description }
}
