import Foundation
import OwlMojoSystem

public final class OwlFreshSessionDirectMojoTransport {
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

    public func setClient(remoteHandle: UInt64) throws {
        try write(
            method: .setClient,
            payload: OwlFreshSessionWireMessage.pendingRemotePayload(),
            handles: [MojoHandle(rawValue: UInt(remoteHandle))]
        )
    }

    public func bindProfile(receiverHandle: UInt64) throws {
        try writeReceiver(method: .bindProfile, receiverHandle: receiverHandle)
    }

    public func bindWebView(receiverHandle: UInt64) throws {
        try writeReceiver(method: .bindWebView, receiverHandle: receiverHandle)
    }

    public func bindInput(receiverHandle: UInt64) throws {
        try writeReceiver(method: .bindInput, receiverHandle: receiverHandle)
    }

    public func bindSurfaceTree(receiverHandle: UInt64) throws {
        try writeReceiver(method: .bindSurfaceTree, receiverHandle: receiverHandle)
    }

    public func bindNativeSurfaceHost(receiverHandle: UInt64) throws {
        try writeReceiver(method: .bindNativeSurfaceHost, receiverHandle: receiverHandle)
    }

    public func bindDevToolsHost(receiverHandle: UInt64) throws {
        try writeReceiver(method: .bindDevToolsHost, receiverHandle: receiverHandle)
    }

    public func flush() throws -> Bool {
        try lock.withLock {
            let requestID = self.consumeRequestID()
            try self.writer.writeMessage(
                pipe: self.remoteHandle,
                data: OwlFreshSessionWireMessage.flushRequestMessage(requestID: requestID),
                handles: []
            )
            let response = try self.readResponse(requestID: requestID)
            return try OwlFreshSessionWireMessage.readFlushResponse(response)
        }
    }

    private func writeReceiver(method: OwlFreshSessionWireMessage.Method, receiverHandle: UInt64) throws {
        try write(
            method: method,
            payload: OwlFreshSessionWireMessage.pendingReceiverPayload(),
            handles: [MojoHandle(rawValue: UInt(receiverHandle))]
        )
    }

    private func write(method: OwlFreshSessionWireMessage.Method, payload: Data, handles: [MojoHandle]) throws {
        try writer.writeMessage(
            pipe: remoteHandle,
            data: OwlFreshSessionWireMessage.message(method: method, payload: payload),
            handles: handles
        )
    }

    private func consumeRequestID() -> UInt64 {
        defer { nextRequestID += 1 }
        return nextRequestID
    }

    private func readResponse(requestID: UInt64) throws -> Data {
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
            let responseRequestID = try OwlFreshSessionWireMessage.responseRequestID(response)
            if responseRequestID < requestID {
                lastStaleResponseID = responseRequestID
                continue
            }
            try OwlFreshSessionWireMessage.validateFlushResponse(response, requestID: requestID)
            return response
        }
    }
}

public enum OwlFreshSessionWireMessage {
    public enum Method: UInt32 {
        case setClient = 0
        case bindProfile = 1
        case bindWebView = 2
        case bindInput = 3
        case bindSurfaceTree = 4
        case bindNativeSurfaceHost = 5
        case bindDevToolsHost = 6
        case flush = 7
    }

    private static let expectsResponseFlag: UInt32 = 1 << 0
    private static let isResponseFlag: UInt32 = 1 << 1
    private static let payloadPointerOffset = 32

    public static func message(method: Method, payload: Data) -> Data {
        MojoWireMessage.message(method: method.rawValue, payload: payload)
    }

    public static func flushRequestMessage(requestID: UInt64) -> Data {
        MojoWireMessage.message(
            method: Method.flush.rawValue,
            payload: emptyPayload(),
            flags: expectsResponseFlag,
            requestID: requestID
        )
    }

    public static func flushResponseMessage(requestID: UInt64, ok: Bool) -> Data {
        var payload = Data(count: 16)
        payload.writeUInt32(16, at: 0)
        payload.writeUInt32(0, at: 4)
        payload[8] = ok ? 1 : 0
        return MojoWireMessage.message(
            method: Method.flush.rawValue,
            payload: payload,
            flags: isResponseFlag,
            requestID: requestID
        )
    }

    public static func pendingRemotePayload(version: UInt32 = 0) -> Data {
        var data = Data(count: 16)
        data.writeUInt32(16, at: 0)
        data.writeUInt32(0, at: 4)
        data.writeUInt32(0, at: 8)
        data.writeUInt32(version, at: 12)
        return data
    }

    public static func pendingReceiverPayload() -> Data {
        var data = Data(count: 16)
        data.writeUInt32(16, at: 0)
        data.writeUInt32(0, at: 4)
        data.writeUInt32(0, at: 8)
        return data
    }

    static func validateFlushResponse(_ data: Data, requestID: UInt64) throws {
        let responseMethod = try data.mojoUInt32(at: 12)
        let responseFlags = try data.mojoUInt32(at: 16)
        let responseRequestID = try responseRequestID(data)
        guard responseMethod == Method.flush.rawValue else {
            throw MojoWireDataError.invalidResponse("expected method \(Method.flush.rawValue), got \(responseMethod)")
        }
        guard responseFlags & isResponseFlag != 0 else {
            throw MojoWireDataError.invalidResponse("OwlFreshSession.Flush was not a response")
        }
        guard responseRequestID == requestID else {
            throw MojoWireDataError.invalidResponse("expected request id \(requestID), got \(responseRequestID)")
        }
    }

    static func responseRequestID(_ data: Data) throws -> UInt64 {
        try data.mojoUInt64(at: 24)
    }

    static func readFlushResponse(_ data: Data) throws -> Bool {
        let payloadOffset = try data.mojoRelativeOffset(pointerOffset: payloadPointerOffset)
        let payloadSize = try data.mojoUInt32(at: payloadOffset)
        guard payloadSize == 16 else {
            throw MojoWireDataError.invalidResponse("Flush response payload is \(payloadSize) bytes")
        }
        return try data.mojoUInt8(at: payloadOffset + 8) != 0
    }

    private static func emptyPayload() -> Data {
        var data = Data(count: 8)
        data.writeUInt32(8, at: 0)
        data.writeUInt32(0, at: 4)
        return data
    }
}
