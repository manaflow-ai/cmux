import Foundation
import OwlMojoBindingsGenerated
import OwlMojoSystem

public final class OwlFreshDevToolsHostDirectMojoTransport {
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

    public func openDevTools(_ mode: OwlFreshDevToolsMode) throws -> Bool {
        try requestBool(method: .openDevTools, payload: OwlFreshDevToolsHostWireMessage.openPayload(mode))
    }

    public func closeDevTools() throws -> Bool {
        try requestBool(method: .closeDevTools, payload: OwlFreshDevToolsHostWireMessage.closePayload())
    }

    public func evaluateDevToolsJavaScript(_ script: String) throws -> String {
        try lock.withLock {
            let requestID = self.consumeRequestID()
            try self.write(
                method: .evaluateDevToolsJavaScript,
                requestID: requestID,
                payload: OwlFreshDevToolsHostWireMessage.evaluatePayload(script)
            )
            let response = try self.readResponse(method: .evaluateDevToolsJavaScript, requestID: requestID)
            return try OwlFreshDevToolsHostWireMessage.readStringResponse(response)
        }
    }

    private func requestBool(method: OwlFreshDevToolsHostWireMessage.Method, payload: Data) throws -> Bool {
        try lock.withLock {
            let requestID = self.consumeRequestID()
            try self.write(method: method, requestID: requestID, payload: payload)
            let response = try self.readResponse(method: method, requestID: requestID)
            return try OwlFreshDevToolsHostWireMessage.readBoolResponse(response)
        }
    }

    private func consumeRequestID() -> UInt64 {
        defer { nextRequestID += 1 }
        return nextRequestID
    }

    private func write(method: OwlFreshDevToolsHostWireMessage.Method, requestID: UInt64, payload: Data) throws {
        try writer.writeMessage(
            pipe: remoteHandle,
            data: OwlFreshDevToolsHostWireMessage.requestMessage(method: method, requestID: requestID, payload: payload),
            handles: []
        )
    }

    private func readResponse(method: OwlFreshDevToolsHostWireMessage.Method, requestID: UInt64) throws -> Data {
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
            let responseRequestID = try OwlFreshDevToolsHostWireMessage.responseRequestID(response)
            if responseRequestID < requestID {
                lastStaleResponseID = responseRequestID
                continue
            }
            try OwlFreshDevToolsHostWireMessage.validateResponse(response, method: method, requestID: requestID)
            return response
        }
    }
}

public enum OwlFreshDevToolsHostWireMessage {
    public enum Method: UInt32 {
        case openDevTools = 0
        case closeDevTools = 1
        case evaluateDevToolsJavaScript = 2
    }

    private static let expectsResponseFlag: UInt32 = 1 << 0
    private static let isResponseFlag: UInt32 = 1 << 1
    private static let payloadPointerOffset = 32

    public static func requestMessage(method: Method, requestID: UInt64, payload: Data) -> Data {
        MojoWireMessage.message(
            method: method.rawValue,
            payload: payload,
            flags: expectsResponseFlag,
            requestID: requestID
        )
    }

    public static func openPayload(_ mode: OwlFreshDevToolsMode) -> Data {
        var data = Data(count: 16)
        data.writeUInt32(16, at: 0)
        data.writeUInt32(0, at: 4)
        data.writeUInt32(mode.rawValue, at: 8)
        return data
    }

    public static func closePayload() -> Data {
        var data = Data(count: 8)
        data.writeUInt32(8, at: 0)
        data.writeUInt32(0, at: 4)
        return data
    }

    public static func evaluatePayload(_ script: String) -> Data {
        let stringData = MojoWireMessage.utf8String(script)
        var data = Data(count: MojoWireMessage.align(16 + stringData.count))
        data.writeUInt32(16, at: 0)
        data.writeUInt32(0, at: 4)
        data.writeUInt64(8, at: 8)
        data.replaceSubrange(16..<16 + stringData.count, with: stringData)
        return data
    }

    public static func boolResponseMessage(method: Method, requestID: UInt64, ok: Bool) -> Data {
        var payload = Data(count: 16)
        payload.writeUInt32(16, at: 0)
        payload.writeUInt32(0, at: 4)
        payload[8] = ok ? 1 : 0
        return MojoWireMessage.message(method: method.rawValue, payload: payload, flags: isResponseFlag, requestID: requestID)
    }

    public static func stringResponseMessage(method: Method, requestID: UInt64, value: String) -> Data {
        let stringData = MojoWireMessage.utf8String(value)
        var payload = Data(count: MojoWireMessage.align(16 + stringData.count))
        payload.writeUInt32(16, at: 0)
        payload.writeUInt32(0, at: 4)
        payload.writeUInt64(8, at: 8)
        payload.replaceSubrange(16..<16 + stringData.count, with: stringData)
        return MojoWireMessage.message(method: method.rawValue, payload: payload, flags: isResponseFlag, requestID: requestID)
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

    static func readBoolResponse(_ data: Data) throws -> Bool {
        let payloadOffset = try payloadOffset(in: data)
        let payloadSize = try data.mojoUInt32(at: payloadOffset)
        guard payloadSize >= 16 else {
            throw MojoWireDataError.invalidResponse("bool response payload is \(payloadSize) bytes")
        }
        _ = try data.mojoUInt32(at: payloadOffset + 8)
        return data[payloadOffset + 8] != 0
    }

    static func readStringResponse(_ data: Data) throws -> String {
        let payloadOffset = try payloadOffset(in: data)
        return try data.mojoString(pointerOffset: payloadOffset + 8)
    }

    private static func payloadOffset(in data: Data) throws -> Int {
        let relative = try data.mojoUInt64(at: payloadPointerOffset)
        guard relative > 0, relative <= UInt64(Int.max) else {
            throw MojoWireDataError.invalidRelativePointer(offset: payloadPointerOffset, relative: relative)
        }
        return payloadPointerOffset + Int(relative)
    }
}
