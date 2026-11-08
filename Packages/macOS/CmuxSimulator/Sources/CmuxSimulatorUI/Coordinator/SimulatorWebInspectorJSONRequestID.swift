import Foundation

enum SimulatorWebInspectorJSONRequestID: Hashable, Sendable {
    case number(String)
    case string(String)
}

private let maximumSimulatorWebInspectorDecodedIDByteCount = 1_024
private let maximumSimulatorWebInspectorSafeInteger = 9_007_199_254_740_991.0

func parseSimulatorWebInspectorJSONRequestID(from json: String) -> SimulatorWebInspectorJSONRequestID? {
    guard let data = json.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data),
          let dictionary = object as? [String: Any] else { return nil }
    return parseSimulatorWebInspectorJSONRequestIDValue(dictionary["id"])
}

func parseSimulatorWebInspectorJSONRequestIDPrefix(
    from data: Data
) -> SimulatorWebInspectorJSONRequestID? {
    let bytes = [UInt8](data)
    var index = skipSimulatorWebInspectorJSONWhitespace(in: bytes, from: 0)
    guard index < bytes.count, bytes[index] == 0x7B else { return nil }
    index += 1
    var depth = 1
    var expectsTopLevelKey = true
    while index < bytes.count {
        index = skipSimulatorWebInspectorJSONWhitespace(in: bytes, from: index)
        guard index < bytes.count else { return nil }
        if depth == 1, expectsTopLevelKey, bytes[index] == 0x22 {
            guard let keyEnd = endOfSimulatorWebInspectorJSONString(in: bytes, from: index),
                  let key = decodeSimulatorWebInspectorJSONString(bytes[index...keyEnd]) else { return nil }
            var colon = skipSimulatorWebInspectorJSONWhitespace(in: bytes, from: keyEnd + 1)
            guard colon < bytes.count, bytes[colon] == 0x3A else { return nil }
            colon = skipSimulatorWebInspectorJSONWhitespace(in: bytes, from: colon + 1)
            if key == "id" {
                return parseSimulatorWebInspectorJSONRequestIDValue(in: bytes, from: colon)
            }
            expectsTopLevelKey = false
            index = keyEnd + 1
            continue
        }
        switch bytes[index] {
        case 0x22:
            guard let end = endOfSimulatorWebInspectorJSONString(in: bytes, from: index) else { return nil }
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

func parseSimulatorWebInspectorJSONRequestIDToken(
    _ data: Data
) -> SimulatorWebInspectorJSONRequestID? {
    guard data.count <= 8 * maximumSimulatorWebInspectorDecodedIDByteCount else { return nil }
    return parseSimulatorWebInspectorJSONRequestID(
        from: "{\"id\":\(String(decoding: data, as: UTF8.self))}"
    )
}

func decodeSimulatorWebInspectorJSONStringToken(_ data: Data) -> String? {
    var array = Data([0x5B])
    array.append(data)
    array.append(0x5D)
    guard let value = try? JSONSerialization.jsonObject(with: array) as? [String],
          let string = value.first,
          string.utf8.count <= maximumSimulatorWebInspectorDecodedIDByteCount else { return nil }
    return string
}

private func parseSimulatorWebInspectorJSONRequestIDValue(
    in bytes: [UInt8],
    from start: Int
) -> SimulatorWebInspectorJSONRequestID? {
    guard start < bytes.count else { return nil }
    let end: Int
    if bytes[start] == 0x22 {
        guard let stringEnd = endOfSimulatorWebInspectorJSONString(in: bytes, from: start) else { return nil }
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
    return parseSimulatorWebInspectorJSONRequestID(
        from: "{\"id\":\(String(decoding: bytes[start..<end], as: UTF8.self))}"
    )
}

private func endOfSimulatorWebInspectorJSONString(in bytes: [UInt8], from start: Int) -> Int? {
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

private func decodeSimulatorWebInspectorJSONString(_ bytes: ArraySlice<UInt8>) -> String? {
    var data = Data([0x5B])
    data.append(contentsOf: bytes)
    data.append(0x5D)
    guard let value = try? JSONSerialization.jsonObject(with: data) as? [String] else { return nil }
    return value.first
}

private func skipSimulatorWebInspectorJSONWhitespace(in bytes: [UInt8], from start: Int) -> Int {
    var index = start
    while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) { index += 1 }
    return index
}

private func parseSimulatorWebInspectorJSONRequestIDValue(
    _ value: Any?
) -> SimulatorWebInspectorJSONRequestID? {
    if let value = value as? String,
       value.utf8.count <= maximumSimulatorWebInspectorDecodedIDByteCount {
        return .string(value)
    }
    guard let number = value as? NSNumber,
          CFGetTypeID(number) != CFBooleanGetTypeID(),
          number.doubleValue.isFinite,
          number.doubleValue.rounded() == number.doubleValue,
          abs(number.doubleValue) <= maximumSimulatorWebInspectorSafeInteger else {
        return nil
    }
    return .number(String(Int64(number.doubleValue)))
}
