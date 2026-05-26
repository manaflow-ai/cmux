import Foundation
import OwlMojoBindingsGenerated
import OwlMojoSystem

public final class OwlFreshSurfaceTreeHostDirectMojoTransport {
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

    public func captureSurface() throws -> OwlFreshCaptureResult {
        let response = try request(method: .captureSurface, payload: OwlFreshSurfaceTreeHostWireMessage.emptyPayload())
        return try OwlFreshSurfaceTreeHostWireMessage.readCaptureResponse(response)
    }

    public func captureSurface(label: String) throws -> OwlFreshCaptureResult {
        let response = try request(
            method: .captureSurfaceByLabel,
            payload: OwlFreshSurfaceTreeHostWireMessage.captureByLabelPayload(label)
        )
        return try OwlFreshSurfaceTreeHostWireMessage.readCaptureResponse(response)
    }

    public func getSurfaceTree() throws -> OwlFreshSurfaceTree {
        let response = try request(method: .getSurfaceTree, payload: OwlFreshSurfaceTreeHostWireMessage.emptyPayload())
        return try OwlFreshSurfaceTreeHostWireMessage.readSurfaceTreeResponse(response)
    }

    private func request(method: OwlFreshSurfaceTreeHostWireMessage.Method, payload: Data) throws -> Data {
        try lock.withLock {
            let requestID = self.consumeRequestID()
            try self.writer.writeMessage(
                pipe: self.remoteHandle,
                data: OwlFreshSurfaceTreeHostWireMessage.requestMessage(
                    method: method,
                    requestID: requestID,
                    payload: payload
                ),
                handles: []
            )
            return try self.readResponse(method: method, requestID: requestID)
        }
    }

    private func consumeRequestID() -> UInt64 {
        defer { nextRequestID += 1 }
        return nextRequestID
    }

    private func readResponse(method: OwlFreshSurfaceTreeHostWireMessage.Method, requestID: UInt64) throws -> Data {
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
            let responseRequestID = try OwlFreshSurfaceTreeHostWireMessage.responseRequestID(response)
            if responseRequestID < requestID {
                lastStaleResponseID = responseRequestID
                continue
            }
            try OwlFreshSurfaceTreeHostWireMessage.validateResponse(response, method: method, requestID: requestID)
            return response
        }
    }
}

public enum OwlFreshSurfaceTreeHostWireMessage {
    public enum Method: UInt32 {
        case captureSurface = 0
        case captureSurfaceByLabel = 1
        case getSurfaceTree = 2
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

    public static func captureByLabelPayload(_ label: String) -> Data {
        let stringData = MojoWireMessage.utf8String(label)
        var data = Data(count: MojoWireMessage.align(16 + stringData.count))
        data.writeUInt32(16, at: 0)
        data.writeUInt32(0, at: 4)
        data.writeUInt64(8, at: 8)
        data.replaceSubrange(16..<16 + stringData.count, with: stringData)
        return data
    }

    public static func captureResponseMessage(
        method: Method,
        requestID: UInt64,
        result: OwlFreshCaptureResult
    ) -> Data {
        var payload = Data(count: 16)
        payload.writeUInt32(16, at: 0)
        payload.writeUInt32(0, at: 4)
        payload.appendMojoPointer(child: captureResultData(result), pointerOffset: 8)
        return MojoWireMessage.message(method: method.rawValue, payload: payload, flags: isResponseFlag, requestID: requestID)
    }

    public static func surfaceTreeResponseMessage(requestID: UInt64, surfaceTree: OwlFreshSurfaceTree) -> Data {
        var payload = Data(count: 16)
        payload.writeUInt32(16, at: 0)
        payload.writeUInt32(0, at: 4)
        payload.appendMojoPointer(child: OwlFreshSurfaceTreeWireCodec.surfaceTreeData(surfaceTree), pointerOffset: 8)
        return MojoWireMessage.message(
            method: Method.getSurfaceTree.rawValue,
            payload: payload,
            flags: isResponseFlag,
            requestID: requestID
        )
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

    static func readCaptureResponse(_ data: Data) throws -> OwlFreshCaptureResult {
        let payloadOffset = try payloadOffset(in: data)
        let resultOffset = try data.mojoRelativeOffset(pointerOffset: payloadOffset + 8)
        return try readCaptureResult(data, at: resultOffset)
    }

    static func readSurfaceTreeResponse(_ data: Data) throws -> OwlFreshSurfaceTree {
        let payloadOffset = try payloadOffset(in: data)
        let treeOffset = try data.mojoRelativeOffset(pointerOffset: payloadOffset + 8)
        return try OwlFreshSurfaceTreeWireCodec.readSurfaceTree(data, at: treeOffset)
    }

    private static func readCaptureResult(_ data: Data, at offset: Int) throws -> OwlFreshCaptureResult {
        let png = try data.mojoUInt8Array(pointerOffset: offset + 8)
        return OwlFreshCaptureResult(
            png: png,
            width: try data.mojoUInt32(at: offset + 16),
            height: try data.mojoUInt32(at: offset + 20),
            captureMode: try data.mojoString(pointerOffset: offset + 24),
            error: try data.mojoString(pointerOffset: offset + 32)
        )
    }

    private static func payloadOffset(in data: Data) throws -> Int {
        try data.mojoRelativeOffset(pointerOffset: payloadPointerOffset)
    }

    private static func captureResultData(_ result: OwlFreshCaptureResult) -> Data {
        var data = Data(count: 40)
        data.writeUInt32(40, at: 0)
        data.writeUInt32(0, at: 4)
        data.appendMojoPointer(child: MojoWireMessage.uint8Array(result.png), pointerOffset: 8)
        data.writeUInt32(result.width, at: 16)
        data.writeUInt32(result.height, at: 20)
        data.appendMojoPointer(child: MojoWireMessage.utf8String(result.captureMode), pointerOffset: 24)
        data.appendMojoPointer(child: MojoWireMessage.utf8String(result.error), pointerOffset: 32)
        return data
    }

}
