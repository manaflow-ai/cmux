import Foundation
import OwlMojoBindingsGenerated
import OwlMojoSystem

public final class OwlFreshProfileDirectMojoTransport {
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

    public func getPath() throws -> String {
        try lock.withLock {
            let requestID = self.consumeRequestID()
            try self.writer.writeMessage(
                pipe: self.remoteHandle,
                data: OwlFreshProfileWireMessage.requestMessage(requestID: requestID),
                handles: []
            )
            let response = try self.readResponse(requestID: requestID)
            return try OwlFreshProfileWireMessage.readGetPathResponse(response)
        }
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
            let responseRequestID = try OwlFreshProfileWireMessage.responseRequestID(response)
            if responseRequestID < requestID {
                lastStaleResponseID = responseRequestID
                continue
            }
            try OwlFreshProfileWireMessage.validateResponse(response, requestID: requestID)
            return response
        }
    }
}

public enum OwlFreshProfileWireMessage {
    public enum Method: UInt32 {
        case getPath = 0
    }

    private static let expectsResponseFlag: UInt32 = 1 << 0
    private static let isResponseFlag: UInt32 = 1 << 1
    private static let payloadPointerOffset = 32

    public static func requestMessage(requestID: UInt64) -> Data {
        MojoWireMessage.message(
            method: Method.getPath.rawValue,
            payload: emptyPayload(),
            flags: expectsResponseFlag,
            requestID: requestID
        )
    }

    public static func responseMessage(requestID: UInt64, path: String) -> Data {
        let stringData = MojoWireMessage.utf8String(path)
        var payload = Data(count: MojoWireMessage.align(16 + stringData.count))
        payload.writeUInt32(16, at: 0)
        payload.writeUInt32(0, at: 4)
        payload.writeUInt64(8, at: 8)
        payload.replaceSubrange(16..<16 + stringData.count, with: stringData)
        return MojoWireMessage.message(
            method: Method.getPath.rawValue,
            payload: payload,
            flags: isResponseFlag,
            requestID: requestID
        )
    }

    static func validateResponse(_ data: Data, requestID: UInt64) throws {
        let responseMethod = try data.mojoUInt32(at: 12)
        let responseFlags = try data.mojoUInt32(at: 16)
        let responseRequestID = try responseRequestID(data)
        guard responseMethod == Method.getPath.rawValue else {
            throw MojoWireDataError.invalidResponse("expected method \(Method.getPath.rawValue), got \(responseMethod)")
        }
        guard responseFlags & isResponseFlag != 0 else {
            throw MojoWireDataError.invalidResponse("OwlFreshProfile.GetPath was not a response")
        }
        guard responseRequestID == requestID else {
            throw MojoWireDataError.invalidResponse("expected request id \(requestID), got \(responseRequestID)")
        }
    }

    static func responseRequestID(_ data: Data) throws -> UInt64 {
        try data.mojoUInt64(at: 24)
    }

    static func readGetPathResponse(_ data: Data) throws -> String {
        let payloadOffset = try data.mojoRelativeOffset(pointerOffset: payloadPointerOffset)
        return try data.mojoString(pointerOffset: payloadOffset + 8)
    }

    private static func emptyPayload() -> Data {
        var data = Data(count: 8)
        data.writeUInt32(8, at: 0)
        data.writeUInt32(0, at: 4)
        return data
    }
}
