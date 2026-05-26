import Foundation
import OwlMojoSystem

public final class OwlFreshNativeSurfaceHostDirectMojoTransport {
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

    public func acceptActivePopupMenuItem(index: UInt32) throws -> Bool {
        try requestBool(
            method: .acceptActivePopupMenuItem,
            payload: OwlFreshNativeSurfaceHostWireMessage.acceptPopupPayload(index: index)
        )
    }

    public func cancelActivePopup() throws -> Bool {
        try requestBool(method: .cancelActivePopup, payload: OwlFreshNativeSurfaceHostWireMessage.emptyPayload())
    }

    public func selectActiveFilePickerFiles(paths: [String]) throws -> Bool {
        try requestBool(
            method: .selectActiveFilePickerFiles,
            payload: OwlFreshNativeSurfaceHostWireMessage.selectFilePickerFilesPayload(paths: paths)
        )
    }

    public func cancelActiveFilePicker() throws -> Bool {
        try requestBool(method: .cancelActiveFilePicker, payload: OwlFreshNativeSurfaceHostWireMessage.emptyPayload())
    }

    public func acceptActivePermissionPrompt() throws -> Bool {
        try requestBool(method: .acceptActivePermissionPrompt, payload: OwlFreshNativeSurfaceHostWireMessage.emptyPayload())
    }

    public func cancelActivePermissionPrompt() throws -> Bool {
        try requestBool(method: .cancelActivePermissionPrompt, payload: OwlFreshNativeSurfaceHostWireMessage.emptyPayload())
    }

    public func submitActiveAuthPrompt(username: String, password: String) throws -> Bool {
        try requestBool(
            method: .submitActiveAuthPrompt,
            payload: OwlFreshNativeSurfaceHostWireMessage.submitAuthPromptPayload(
                username: username,
                password: password
            )
        )
    }

    public func cancelActiveAuthPrompt() throws -> Bool {
        try requestBool(method: .cancelActiveAuthPrompt, payload: OwlFreshNativeSurfaceHostWireMessage.emptyPayload())
    }

    private func requestBool(method: OwlFreshNativeSurfaceHostWireMessage.Method, payload: Data) throws -> Bool {
        try lock.withLock {
            let requestID = self.consumeRequestID()
            try self.writer.writeMessage(
                pipe: self.remoteHandle,
                data: OwlFreshNativeSurfaceHostWireMessage.requestMessage(
                    method: method,
                    requestID: requestID,
                    payload: payload
                ),
                handles: []
            )
            let response = try self.readResponse(method: method, requestID: requestID)
            return try OwlFreshNativeSurfaceHostWireMessage.readBoolResponse(response)
        }
    }

    private func consumeRequestID() -> UInt64 {
        defer { nextRequestID += 1 }
        return nextRequestID
    }

    private func readResponse(method: OwlFreshNativeSurfaceHostWireMessage.Method, requestID: UInt64) throws -> Data {
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
            let responseRequestID = try OwlFreshNativeSurfaceHostWireMessage.responseRequestID(response)
            if responseRequestID < requestID {
                lastStaleResponseID = responseRequestID
                continue
            }
            try OwlFreshNativeSurfaceHostWireMessage.validateResponse(response, method: method, requestID: requestID)
            return response
        }
    }
}

public enum OwlFreshNativeSurfaceHostWireMessage {
    public enum Method: UInt32 {
        case acceptActivePopupMenuItem = 0
        case cancelActivePopup = 1
        case selectActiveFilePickerFiles = 2
        case cancelActiveFilePicker = 3
        case acceptActivePermissionPrompt = 4
        case cancelActivePermissionPrompt = 5
        case submitActiveAuthPrompt = 6
        case cancelActiveAuthPrompt = 7
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

    public static func emptyPayload() -> Data {
        var data = Data(count: 8)
        data.writeUInt32(8, at: 0)
        data.writeUInt32(0, at: 4)
        return data
    }

    public static func acceptPopupPayload(index: UInt32) -> Data {
        var data = Data(count: 16)
        data.writeUInt32(16, at: 0)
        data.writeUInt32(0, at: 4)
        data.writeUInt32(index, at: 8)
        return data
    }

    public static func selectFilePickerFilesPayload(paths: [String]) -> Data {
        var data = Data(count: 16)
        data.writeUInt32(16, at: 0)
        data.writeUInt32(0, at: 4)
        data.appendMojoPointer(child: MojoWireMessage.stringArray(paths), pointerOffset: 8)
        return data
    }

    public static func submitAuthPromptPayload(username: String, password: String) -> Data {
        var data = Data(count: 24)
        data.writeUInt32(24, at: 0)
        data.writeUInt32(0, at: 4)
        data.appendMojoPointer(child: MojoWireMessage.utf8String(username), pointerOffset: 8)
        data.appendMojoPointer(child: MojoWireMessage.utf8String(password), pointerOffset: 16)
        return data
    }

    public static func boolResponseMessage(method: Method, requestID: UInt64, ok: Bool) -> Data {
        var payload = Data(count: 16)
        payload.writeUInt32(16, at: 0)
        payload.writeUInt32(0, at: 4)
        payload[8] = ok ? 1 : 0
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
        let payloadOffset = try data.mojoRelativeOffset(pointerOffset: payloadPointerOffset)
        let payloadSize = try data.mojoUInt32(at: payloadOffset)
        guard payloadSize >= 16 else {
            throw MojoWireDataError.invalidResponse("bool response payload is \(payloadSize) bytes")
        }
        return try data.mojoUInt8(at: payloadOffset + 8) != 0
    }
}
