import Foundation
import Network

nonisolated public protocol CmxFrameTransport: Sendable {
    func open() async throws
    func sendFrame(_ payload: Data) async throws
    func receiveFrame() async throws -> Data?
    func close() async
}

nonisolated public enum CmxTransportError: Error, Equatable, LocalizedError {
    case invalidFrameLength(Int)
    case connectionClosed

    public var errorDescription: String? {
        switch self {
        case .invalidFrameLength(let length):
            "Invalid cmx frame length \(length)."
        case .connectionClosed:
            "The cmx connection closed."
        }
    }
}

public actor CmxConnection {
    private let transport: any CmxFrameTransport
    private var receiveTask: Task<Void, Never>?
    private var continuation: AsyncThrowingStream<CmxServerMessage, Error>.Continuation?
    private var nextCommandID: UInt32 = 1

    public init(transport: any CmxFrameTransport) {
        self.transport = transport
    }

    deinit {
        receiveTask?.cancel()
    }

    public func connectNative(
        viewport: CmxWireViewport,
        token: String? = nil,
        clientKind: CmxNativeClientKind = .desktop,
        clientID: String? = nil,
        windowID: String? = nil,
        capabilities: [CmxNativeClientCapability] = [.libghosttyPtyBytes]
    ) async throws -> AsyncThrowingStream<CmxServerMessage, Error> {
        let stream = try await startReceiving()
        try await send(.helloNative(
            viewport: viewport,
            token: token,
            clientKind: clientKind,
            clientID: clientID,
            windowID: windowID,
            capabilities: capabilities
        ))
        return stream
    }

    public func startReceiving() async throws -> AsyncThrowingStream<CmxServerMessage, Error> {
        receiveTask?.cancel()
        try await transport.open()

        let pair = AsyncThrowingStream<CmxServerMessage, Error>.makeStream()
        continuation = pair.continuation
        receiveTask = Task { [weak self] in
            await self?.receiveLoop()
        }
        return pair.stream
    }

    public func send(_ message: CmxClientMessage) async throws {
        try await transport.sendFrame(CmxWireCodec.encode(message))
    }

    @discardableResult
    public func sendCommand(_ command: CmxClientCommand) async throws -> UInt32 {
        let id = nextCommandID
        nextCommandID = nextCommandID == UInt32.max ? 1 : nextCommandID + 1
        try await send(.command(id: id, command))
        return id
    }

    public func sendInput(_ data: Data, terminalID: UInt64) async throws {
        try await send(.nativeInput(tabID: terminalID, data: data))
    }

    public func sendLayout(_ terminals: [CmxWireTerminalViewport]) async throws {
        try await send(.nativeLayout(terminals))
    }

    public func requestPtyReplay(terminalID: UInt64, fromSeq: UInt64? = nil) async throws {
        try await send(.requestPtyReplay(tabID: terminalID, fromSeq: fromSeq))
    }

    public func sendBrowserUpdate(_ browser: CmxNativeBrowserInfo, browserID: UInt64) async throws {
        try await send(.nativeBrowserUpdate(tabID: browserID, browser: browser))
    }

    public func sendBrowserFocusUpdate(webViewFocused: Bool, browserID: UInt64) async throws {
        try await send(.nativeBrowserFocusUpdate(tabID: browserID, webViewFocused: webViewFocused))
    }

    public func sendCompatibilityReply(requestID: UInt64, responseJSON: String) async throws {
        try await send(.nativeCompatibilityReply(requestID: requestID, responseJSON: responseJSON))
    }

    public func close() async {
        receiveTask?.cancel()
        receiveTask = nil
        continuation?.finish()
        continuation = nil
        try? await transport.sendFrame(CmxWireCodec.encode(.detach))
        await transport.close()
    }

    private func receiveLoop() async {
        do {
            while !Task.isCancelled {
                guard let payload = try await transport.receiveFrame() else {
                    break
                }
                let message = try CmxWireCodec.decodeServerMessage(payload)
                continuation?.yield(message)
                if case .bye = message {
                    break
                }
            }
            continuation?.finish()
        } catch {
            continuation?.finish(throwing: error)
        }
    }
}

public final class CmxUnixSocketTransport: CmxFrameTransport, @unchecked Sendable {
    private let connection: NWConnection
    private let queue: DispatchQueue

    public init(path: String) {
        self.connection = NWConnection(to: .unix(path: path), using: .tcp)
        self.queue = DispatchQueue(label: "com.cmux.cmx.unix-socket.\(UUID().uuidString)", qos: .userInitiated)
        connection.start(queue: queue)
    }

    public func open() async throws {}

    public func sendFrame(_ payload: Data) async throws {
        let framed = try CmxWireCodec.frame(payload)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: framed, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }

    public func receiveFrame() async throws -> Data? {
        guard let header = try await receiveExactly(byteCount: 4) else {
            return nil
        }
        let length = header.reduce(UInt32(0)) { partial, byte in
            (partial << 8) | UInt32(byte)
        }
        guard length <= UInt32(Int32.max) else {
            throw CmxTransportError.invalidFrameLength(Int(length))
        }
        if length == 0 {
            return Data()
        }
        return try await receiveExactly(byteCount: Int(length))
    }

    public func close() async {
        connection.cancel()
    }

    private func receiveExactly(byteCount: Int) async throws -> Data? {
        var payload = Data()
        payload.reserveCapacity(byteCount)
        while payload.count < byteCount {
            let chunk = try await receiveChunk(maximumLength: byteCount - payload.count)
            guard let chunk else {
                if payload.isEmpty {
                    return nil
                }
                throw CmxTransportError.connectionClosed
            }
            guard !chunk.isEmpty else {
                continue
            }
            payload.append(chunk)
        }
        return payload
    }

    private func receiveChunk(maximumLength: Int) async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(
                minimumIncompleteLength: 1,
                maximumLength: maximumLength
            ) { content, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                if let content, !content.isEmpty {
                    continuation.resume(returning: content)
                    return
                }
                continuation.resume(returning: isComplete ? nil : Data())
            }
        }
    }
}
