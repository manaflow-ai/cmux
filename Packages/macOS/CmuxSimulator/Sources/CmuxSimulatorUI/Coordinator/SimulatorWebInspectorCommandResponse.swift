import CmuxSimulator
import Foundation

/// One bounded raw response matched to a Web Inspector JSON request id.
public struct SimulatorWebInspectorCommandResponse: Equatable, Sendable {
    public let text: String
    public let isTruncated: Bool

    public init(text: String, isTruncated: Bool) {
        self.text = text
        self.isTruncated = isTruncated
    }
}

enum SimulatorWebInspectorJSONRequestID: Hashable, Sendable {
    private static let maximumDecodedByteCount = 1_024

    case number(String)
    case string(String)

    static func parse(from json: String) -> Self? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else { return nil }
        return parse(dictionary["id"])
    }

    static func parsePrefix(from data: Data) -> Self? {
        let bytes = [UInt8](data)
        var index = skipWhitespace(in: bytes, from: 0)
        guard index < bytes.count, bytes[index] == 0x7B else { return nil }
        index += 1
        var depth = 1
        var expectsTopLevelKey = true
        while index < bytes.count {
            index = skipWhitespace(in: bytes, from: index)
            guard index < bytes.count else { return nil }
            if depth == 1, expectsTopLevelKey, bytes[index] == 0x22 {
                guard let keyEnd = endOfJSONString(in: bytes, from: index),
                      let key = decodedJSONString(bytes[index...keyEnd]) else { return nil }
                var colon = skipWhitespace(in: bytes, from: keyEnd + 1)
                guard colon < bytes.count, bytes[colon] == 0x3A else { return nil }
                colon = skipWhitespace(in: bytes, from: colon + 1)
                if key == "id" { return parseIDValue(in: bytes, from: colon) }
                expectsTopLevelKey = false
                index = keyEnd + 1
                continue
            }
            switch bytes[index] {
            case 0x22:
                guard let end = endOfJSONString(in: bytes, from: index) else { return nil }
                index = end + 1
            case 0x7B, 0x5B:
                depth += 1
                index += 1
            case 0x7D, 0x5D:
                depth -= 1
                if depth == 0 { return nil }
                index += 1
            case 0x2C:
                if depth == 1 { expectsTopLevelKey = true }
                index += 1
            default:
                index += 1
            }
        }
        return nil
    }

    static func parseValueToken(_ data: Data) -> Self? {
        guard data.count <= 8 * maximumDecodedByteCount else { return nil }
        return parse(from: "{\"id\":\(String(decoding: data, as: UTF8.self))}")
    }

    static func decodeStringToken(_ data: Data) -> String? {
        var array = Data([0x5B])
        array.append(data)
        array.append(0x5D)
        guard let value = try? JSONSerialization.jsonObject(with: array) as? [String],
              let string = value.first,
              string.utf8.count <= maximumDecodedByteCount else { return nil }
        return string
    }

    private static func parseIDValue(in bytes: [UInt8], from start: Int) -> Self? {
        guard start < bytes.count else { return nil }
        let end: Int
        if bytes[start] == 0x22 {
            guard let stringEnd = endOfJSONString(in: bytes, from: start) else { return nil }
            end = stringEnd + 1
        } else {
            var cursor = start
            while cursor < bytes.count,
                  ![0x2C, 0x7D, 0x5D, 0x20, 0x09, 0x0A, 0x0D].contains(bytes[cursor]) {
                cursor += 1
            }
            guard cursor > start else { return nil }
            end = cursor
        }
        return parse(from: "{\"id\":\(String(decoding: bytes[start..<end], as: UTF8.self))}")
    }

    private static func endOfJSONString(in bytes: [UInt8], from start: Int) -> Int? {
        var index = start + 1
        var escaped = false
        while index < bytes.count {
            if escaped { escaped = false }
            else if bytes[index] == 0x5C { escaped = true }
            else if bytes[index] == 0x22 { return index }
            index += 1
        }
        return nil
    }

    private static func decodedJSONString(_ bytes: ArraySlice<UInt8>) -> String? {
        var data = Data([0x5B])
        data.append(contentsOf: bytes)
        data.append(0x5D)
        guard let value = try? JSONSerialization.jsonObject(with: data) as? [String] else { return nil }
        return value.first
    }

    private static func skipWhitespace(in bytes: [UInt8], from start: Int) -> Int {
        var index = start
        while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) { index += 1 }
        return index
    }

    private static func parse(_ value: Any?) -> Self? {
        if let value = value as? String,
           value.utf8.count <= maximumDecodedByteCount { return .string(value) }
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.stringValue.utf8.count <= maximumDecodedByteCount else { return nil }
        return .number(number.stringValue)
    }
}

struct SimulatorPendingWebInspectorResponse {
    let continuation: CheckedContinuation<
        Result<SimulatorWebInspectorCommandResponse, SimulatorFailure>,
        Never
    >
    let timeoutTask: Task<Void, Never>
}
