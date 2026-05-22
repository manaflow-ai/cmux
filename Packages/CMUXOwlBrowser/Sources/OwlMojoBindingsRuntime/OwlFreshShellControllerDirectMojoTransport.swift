import Foundation
import OwlMojoSystem

public final class OwlFreshShellControllerDirectMojoTransport {
    private let writer: MojoMessageWriting
    private let reader: MojoMessageReading
    private let closer: MojoMessagePipeCreating
    private let remoteHandle: MojoHandle
    private let responseTimeout: TimeInterval
    private let lock = NSLock()
    private var ownsRemoteHandle = true
    private var nextRequestID: UInt64 = 1

    public init(
        writer: MojoMessageWriting,
        reader: MojoMessageReading,
        closer: MojoMessagePipeCreating,
        remoteHandle: UInt64,
        responseTimeout: TimeInterval = 30
    ) {
        self.writer = writer
        self.reader = reader
        self.closer = closer
        self.remoteHandle = MojoHandle(rawValue: UInt(remoteHandle))
        self.responseTimeout = responseTimeout
    }

    deinit {
        if ownsRemoteHandle {
            try? closer.close(remoteHandle)
        }
    }

    public func bindOwlFreshSession(receiverHandle: UInt64) throws {
        try writer.writeMessage(
            pipe: remoteHandle,
            data: OwlFreshShellControllerWireMessage.message(
                method: .bindOwlFreshSession,
                payload: OwlFreshShellControllerWireMessage.pendingReceiverPayload()
            ),
            handles: [MojoHandle(rawValue: UInt(receiverHandle))]
        )
    }

    public func executeJavaScript(_ script: String) throws -> String {
        try lock.withLock {
            let requestID = self.consumeRequestID()
            try self.writer.writeMessage(
                pipe: self.remoteHandle,
                data: OwlFreshShellControllerWireMessage.executeJavaScriptRequestMessage(
                    requestID: requestID,
                    script: script
                ),
                handles: []
            )
            let response = try self.readResponse(method: .executeJavaScript, requestID: requestID)
            return try OwlFreshShellControllerWireMessage.readExecuteJavaScriptJSONResponse(response)
        }
    }

    public func shutdown() throws {
        try writer.writeMessage(
            pipe: remoteHandle,
            data: OwlFreshShellControllerWireMessage.message(
                method: .shutdown,
                payload: OwlFreshShellControllerWireMessage.emptyPayload()
            ),
            handles: []
        )
    }

    private func consumeRequestID() -> UInt64 {
        defer { nextRequestID += 1 }
        return nextRequestID
    }

    private func readResponse(method: OwlFreshShellControllerWireMessage.Method, requestID: UInt64) throws -> Data {
        let deadline = Date().addingTimeInterval(responseTimeout)
        var lastStaleResponseID: UInt64?
        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else {
                if let lastStaleResponseID {
                    throw MojoWireDataError.invalidResponse(
                        "timed out waiting for request id \(requestID) after stale response id \(lastStaleResponseID)"
                    )
                }
                throw MojoWireDataError.invalidResponse("timed out waiting for request id \(requestID)")
            }
            let response = try reader.readMessage(pipe: remoteHandle, timeout: remaining)
            let responseRequestID = try OwlFreshShellControllerWireMessage.responseRequestID(response)
            if responseRequestID < requestID {
                lastStaleResponseID = responseRequestID
                continue
            }
            try OwlFreshShellControllerWireMessage.validateResponse(response, method: method, requestID: requestID)
            return response
        }
    }
}

public enum OwlFreshShellControllerWireMessage {
    public enum Method: UInt32 {
        case getSwitchValue = 0
        case executeJavaScript = 1
        case shutdown = 2
        case bindOwlFreshSession = 3
    }

    private static let expectsResponseFlag: UInt32 = 1 << 0
    private static let isResponseFlag: UInt32 = 1 << 1
    private static let payloadPointerOffset = 32

    public static func message(method: Method, payload: Data) -> Data {
        MojoWireMessage.message(method: method.rawValue, payload: payload)
    }

    public static func executeJavaScriptRequestMessage(requestID: UInt64, script: String) -> Data {
        MojoWireMessage.message(
            method: Method.executeJavaScript.rawValue,
            payload: executeJavaScriptPayload(script),
            flags: expectsResponseFlag,
            requestID: requestID
        )
    }

    public static func executeJavaScriptResponseMessage(requestID: UInt64, value: MojoBaseValue) -> Data {
        var payload = Data(count: 24)
        payload.writeUInt32(24, at: 0)
        payload.writeUInt32(0, at: 4)
        MojoBaseValueWireCodec.write(value, into: &payload, unionOffset: 8)
        return MojoWireMessage.message(
            method: Method.executeJavaScript.rawValue,
            payload: payload,
            flags: isResponseFlag,
            requestID: requestID
        )
    }

    public static func pendingReceiverPayload() -> Data {
        var data = Data(count: 16)
        data.writeUInt32(16, at: 0)
        data.writeUInt32(0, at: 4)
        data.writeUInt32(0, at: 8)
        return data
    }

    public static func emptyPayload() -> Data {
        var data = Data(count: 8)
        data.writeUInt32(8, at: 0)
        data.writeUInt32(0, at: 4)
        return data
    }

    static func validateResponse(_ data: Data, method: Method, requestID: UInt64) throws {
        let responseMethod = try data.mojoUInt32(at: 12)
        let responseFlags = try data.mojoUInt32(at: 16)
        let responseRequestID = try responseRequestID(data)
        guard responseMethod == method.rawValue else {
            throw MojoWireDataError.invalidResponse("expected method \(method.rawValue), got \(responseMethod)")
        }
        guard responseFlags & isResponseFlag != 0 else {
            throw MojoWireDataError.invalidResponse("message for method \(method.rawValue) is not a response")
        }
        guard responseRequestID == requestID else {
            throw MojoWireDataError.invalidResponse("expected request id \(requestID), got \(responseRequestID)")
        }
    }

    static func responseRequestID(_ data: Data) throws -> UInt64 {
        try data.mojoUInt64(at: 24)
    }

    static func readExecuteJavaScriptJSONResponse(_ data: Data) throws -> String {
        let payloadOffset = try data.mojoRelativeOffset(pointerOffset: payloadPointerOffset)
        let payloadSize = try data.mojoUInt32(at: payloadOffset)
        guard payloadSize >= 24 else {
            throw MojoWireDataError.invalidResponse("ShellController.ExecuteJavaScript response payload is \(payloadSize) bytes")
        }
        let value = try MojoBaseValueWireCodec.readValue(from: data, unionOffset: payloadOffset + 8)
        return try value.jsonString()
    }

    private static func executeJavaScriptPayload(_ script: String) -> Data {
        let scriptData = MojoWireMessage.string16(script)
        var data = Data(count: MojoWireMessage.align(16 + scriptData.count))
        data.writeUInt32(16, at: 0)
        data.writeUInt32(0, at: 4)
        data.writeUInt64(8, at: 8)
        data.replaceSubrange(16..<16 + scriptData.count, with: scriptData)
        return data
    }
}

public enum MojoBaseValue: Equatable {
    case null
    case bool(Bool)
    case int(Int32)
    case double(Double)
    case string(String)
    case binary([UInt8])
    case dictionary([String: MojoBaseValue])
    case list([MojoBaseValue])

    public func jsonString() throws -> String {
        switch self {
        case .null:
            return "null"
        case let .bool(value):
            return value ? "true" : "false"
        case let .int(value):
            return String(value)
        case let .double(value):
            guard value.isFinite else {
                throw MojoWireDataError.invalidResponse("mojo_base.Value double is not finite")
            }
            return String(value)
        case let .string(value):
            return Self.quoted(value)
        case .binary:
            throw MojoWireDataError.invalidResponse("mojo_base.Value binary cannot be represented as JSON")
        case let .dictionary(values):
            let entries = try values.keys.sorted().map { key in
                try "\(Self.quoted(key)):\(values[key]!.jsonString())"
            }
            return "{\(entries.joined(separator: ","))}"
        case let .list(values):
            return try "[\(values.map { try $0.jsonString() }.joined(separator: ","))]"
        }
    }

    private static func quoted(_ value: String) -> String {
        var result = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"":
                result += "\\\""
            case "\\":
                result += "\\\\"
            case "\n":
                result += "\\n"
            case "\r":
                result += "\\r"
            case "\t":
                result += "\\t"
            case "\u{08}":
                result += "\\b"
            case "\u{0C}":
                result += "\\f"
            default:
                if scalar.value < 0x20 {
                    result += String(format: "\\u%04X", scalar.value)
                } else {
                    result += String(scalar)
                }
            }
        }
        result += "\""
        return result
    }
}

enum MojoBaseValueWireCodec {
    private enum Tag: UInt32 {
        case nullValue = 0
        case boolValue = 1
        case intValue = 2
        case doubleValue = 3
        case stringValue = 4
        case binaryValue = 5
        case dictionaryValue = 6
        case listValue = 7
    }

    static func readValue(from data: Data, unionOffset: Int) throws -> MojoBaseValue {
        let size = try data.mojoUInt32(at: unionOffset)
        if size == 0 {
            return .null
        }
        guard size == 16 else {
            throw MojoWireDataError.invalidResponse("mojo_base.Value union is \(size) bytes")
        }
        guard let tag = Tag(rawValue: try data.mojoUInt32(at: unionOffset + 4)) else {
            throw MojoWireDataError.invalidResponse("unknown mojo_base.Value tag \(try data.mojoUInt32(at: unionOffset + 4))")
        }
        switch tag {
        case .nullValue:
            return .null
        case .boolValue:
            return .bool(try data.mojoUInt8(at: unionOffset + 8) != 0)
        case .intValue:
            return .int(try data.mojoInt32(at: unionOffset + 8))
        case .doubleValue:
            return .double(Double(bitPattern: try data.mojoUInt64(at: unionOffset + 8)))
        case .stringValue:
            return .string(try data.mojoString(pointerOffset: unionOffset + 8))
        case .binaryValue:
            return .binary(try data.mojoUInt8Array(pointerOffset: unionOffset + 8))
        case .dictionaryValue:
            return .dictionary(try readDictionary(from: data, pointerOffset: unionOffset + 8))
        case .listValue:
            return .list(try readList(from: data, pointerOffset: unionOffset + 8))
        }
    }

    static func write(_ value: MojoBaseValue, into data: inout Data, unionOffset: Int) {
        data.writeUInt32(16, at: unionOffset)
        switch value {
        case .null:
            data.writeUInt32(Tag.nullValue.rawValue, at: unionOffset + 4)
        case let .bool(value):
            data.writeUInt32(Tag.boolValue.rawValue, at: unionOffset + 4)
            data[unionOffset + 8] = value ? 1 : 0
        case let .int(value):
            data.writeUInt32(Tag.intValue.rawValue, at: unionOffset + 4)
            data.writeInt32(value, at: unionOffset + 8)
        case let .double(value):
            data.writeUInt32(Tag.doubleValue.rawValue, at: unionOffset + 4)
            data.writeDouble(value, at: unionOffset + 8)
        case let .string(value):
            data.writeUInt32(Tag.stringValue.rawValue, at: unionOffset + 4)
            data.appendMojoPointer(child: MojoWireMessage.utf8String(value), pointerOffset: unionOffset + 8)
        case let .binary(value):
            data.writeUInt32(Tag.binaryValue.rawValue, at: unionOffset + 4)
            data.appendMojoPointer(child: MojoWireMessage.uint8Array(value), pointerOffset: unionOffset + 8)
        case let .dictionary(value):
            data.writeUInt32(Tag.dictionaryValue.rawValue, at: unionOffset + 4)
            data.appendMojoPointer(child: dictionaryData(value), pointerOffset: unionOffset + 8)
        case let .list(value):
            data.writeUInt32(Tag.listValue.rawValue, at: unionOffset + 4)
            data.appendMojoPointer(child: listData(value), pointerOffset: unionOffset + 8)
        }
    }

    private static func readDictionary(from data: Data, pointerOffset: Int) throws -> [String: MojoBaseValue] {
        let dictionaryOffset = try data.mojoRelativeOffset(pointerOffset: pointerOffset)
        let dictionarySize = try data.mojoUInt32(at: dictionaryOffset)
        guard dictionarySize >= 16 else {
            throw MojoWireDataError.invalidResponse("DictionaryValue struct is \(dictionarySize) bytes")
        }
        let mapOffset = try data.mojoRelativeOffset(pointerOffset: dictionaryOffset + 8)
        let mapSize = try data.mojoUInt32(at: mapOffset)
        guard mapSize >= 24 else {
            throw MojoWireDataError.invalidResponse("DictionaryValue map is \(mapSize) bytes")
        }

        let keys = try readStringPointerArray(from: data, pointerOffset: mapOffset + 8)
        let values = try readValueArray(from: data, pointerOffset: mapOffset + 16)
        guard keys.count == values.count else {
            throw MojoWireDataError.invalidResponse("DictionaryValue has \(keys.count) keys and \(values.count) values")
        }

        var result: [String: MojoBaseValue] = [:]
        for (key, value) in zip(keys, values) {
            result[key] = value
        }
        return result
    }

    private static func readList(from data: Data, pointerOffset: Int) throws -> [MojoBaseValue] {
        let listOffset = try data.mojoRelativeOffset(pointerOffset: pointerOffset)
        let listSize = try data.mojoUInt32(at: listOffset)
        guard listSize >= 16 else {
            throw MojoWireDataError.invalidResponse("ListValue struct is \(listSize) bytes")
        }
        return try readValueArray(from: data, pointerOffset: listOffset + 8)
    }

    private static func readStringPointerArray(from data: Data, pointerOffset: Int) throws -> [String] {
        let array = try readArrayHeader(from: data, pointerOffset: pointerOffset)
        try requireRange(data, offset: array.elementsOffset, length: array.count * 8)
        var result: [String] = []
        result.reserveCapacity(array.count)
        for index in 0..<array.count {
            result.append(try data.mojoString(pointerOffset: array.elementsOffset + index * 8))
        }
        return result
    }

    private static func readValueArray(from data: Data, pointerOffset: Int) throws -> [MojoBaseValue] {
        let array = try readArrayHeader(from: data, pointerOffset: pointerOffset)
        try requireRange(data, offset: array.elementsOffset, length: array.count * 16)
        var result: [MojoBaseValue] = []
        result.reserveCapacity(array.count)
        for index in 0..<array.count {
            result.append(try readValue(from: data, unionOffset: array.elementsOffset + index * 16))
        }
        return result
    }

    private static func readArrayHeader(from data: Data, pointerOffset: Int) throws -> (elementsOffset: Int, count: Int) {
        let arrayOffset = try data.mojoRelativeOffset(pointerOffset: pointerOffset)
        let byteCount = Int(try data.mojoUInt32(at: arrayOffset))
        let count = Int(try data.mojoUInt32(at: arrayOffset + 4))
        guard byteCount >= 8 else {
            throw MojoWireDataError.outOfBounds(offset: arrayOffset, length: byteCount, count: data.count)
        }
        try requireRange(data, offset: arrayOffset, length: byteCount)
        return (elementsOffset: arrayOffset + 8, count: count)
    }

    private static func requireRange(_ data: Data, offset: Int, length: Int) throws {
        guard offset >= 0, length >= 0, offset <= data.count, offset + length <= data.count else {
            throw MojoWireDataError.outOfBounds(offset: offset, length: length, count: data.count)
        }
    }

    private static func dictionaryData(_ value: [String: MojoBaseValue]) -> Data {
        var data = Data(count: 16)
        data.writeUInt32(16, at: 0)
        data.writeUInt32(0, at: 4)
        data.appendMojoPointer(child: mapData(value), pointerOffset: 8)
        return data
    }

    private static func mapData(_ value: [String: MojoBaseValue]) -> Data {
        let keys = value.keys.sorted()
        var data = Data(count: 24)
        data.writeUInt32(24, at: 0)
        data.writeUInt32(0, at: 4)
        data.appendMojoPointer(child: stringPointerArrayData(keys), pointerOffset: 8)
        data.appendMojoPointer(child: valueArrayData(keys.map { value[$0]! }), pointerOffset: 16)
        return data
    }

    private static func listData(_ value: [MojoBaseValue]) -> Data {
        var data = Data(count: 16)
        data.writeUInt32(16, at: 0)
        data.writeUInt32(0, at: 4)
        data.appendMojoPointer(child: valueArrayData(value), pointerOffset: 8)
        return data
    }

    private static func stringPointerArrayData(_ values: [String]) -> Data {
        var data = Data(count: MojoWireMessage.align(8 + values.count * 8))
        data.writeUInt32(UInt32(8 + values.count * 8), at: 0)
        data.writeUInt32(UInt32(values.count), at: 4)
        for (index, value) in values.enumerated() {
            data.appendMojoPointer(child: MojoWireMessage.utf8String(value), pointerOffset: 8 + index * 8)
        }
        return data
    }

    private static func valueArrayData(_ values: [MojoBaseValue]) -> Data {
        var data = Data(count: MojoWireMessage.align(8 + values.count * 16))
        data.writeUInt32(UInt32(8 + values.count * 16), at: 0)
        data.writeUInt32(UInt32(values.count), at: 4)
        for (index, value) in values.enumerated() {
            write(value, into: &data, unionOffset: 8 + index * 16)
        }
        return data
    }
}
