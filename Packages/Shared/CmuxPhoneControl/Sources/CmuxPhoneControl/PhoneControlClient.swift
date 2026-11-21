#if canImport(Network)
import Foundation
import Network

/// Errors raised while an agent client is talking to the local phone channel.
public enum PhoneControlClientError: Error, Equatable, Sendable {
    case invalidEndpoint
    case connectionClosed
    case noSession
    case transport(String)
    case malformedResponse(String)
    case unexpectedResponse(String)
    case remote(PhoneError)
}

/// The client deliberately accepts loopback hosts only. A caller that needs a
/// remote device must establish an authenticated tunnel outside this package.
public struct PhoneControlClientConfiguration: Equatable, Sendable {
    public let host: String
    public let port: UInt16

    public init(host: String = "127.0.0.1", port: UInt16) throws {
        let normalizedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard Self.isLoopbackHost(normalizedHost), port != 0 else {
            throw PhoneControlClientError.invalidEndpoint
        }
        self.host = normalizedHost
        self.port = port
    }

    fileprivate static func isLoopbackHost(_ host: String) -> Bool {
        ["127.0.0.1", "localhost", "::1", "[::1]"].contains(host)
    }
}

/// The typed result returned by `session.open`.
public struct PhoneSessionInfo: Codable, Equatable, Sendable {
    public let sessionID: String
    public let device: PhoneDevice
    public let capabilities: PhoneCapabilities

    public init(
        sessionID: String,
        device: PhoneDevice,
        capabilities: PhoneCapabilities
    ) {
        self.sessionID = sessionID
        self.device = device
        self.capabilities = capabilities
    }
}

/// A serial, typed client for the loopback newline-JSON channel.
///
/// Requests are serialized so a caller can safely retry an action after a
/// transport interruption using the same `action_id`. Events received while a
/// request is outstanding are retained by `drainEvents()`.
public actor PhoneControlClient {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let requestGate = PhoneRequestGate()
    private let codec = PhoneWireCodec()
    private var decoder = PhoneLineDecoder(maxLineBytes: PhoneProtocol.maxResponseLineBytes)
    private var bufferedMessages: [PhoneEnvelope] = []
    private var bufferedEvents: [PhoneEnvelope] = []
    private var requestCounter: UInt64 = 0
    private var connected = false
    private var closed = false
    private var activeSessionID: String?

    public init(configuration: PhoneControlClientConfiguration) {
        connection = NWConnection(
            host: NWEndpoint.Host(configuration.host),
            port: NWEndpoint.Port(rawValue: configuration.port)!,
            using: .tcp
        )
        queue = DispatchQueue(label: "com.cmux.phone-control.client")
    }

    public init(host: String = "127.0.0.1", port: UInt16) throws {
        let configuration = try PhoneControlClientConfiguration(host: host, port: port)
        connection = NWConnection(
            host: NWEndpoint.Host(configuration.host),
            port: NWEndpoint.Port(rawValue: configuration.port)!,
            using: .tcp
        )
        queue = DispatchQueue(label: "com.cmux.phone-control.client")
    }

    /// The session opened through `openSession`, if one is active.
    public var sessionID: String? { activeSessionID }

    public func connect() async throws {
        guard !closed else { throw PhoneControlClientError.connectionClosed }
        guard !connected else { return }

        let gate = ThrowingContinuationGate<Void>()
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                gate.install(continuation)
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        gate.resume(.success(()))
                    case .failed(let error):
                        gate.resume(.failure(PhoneControlClientError.transport(String(describing: error))))
                    case .cancelled:
                        gate.resume(.failure(PhoneControlClientError.connectionClosed))
                    default:
                        break
                    }
                }
                connection.start(queue: queue)
            }
        }, onCancel: {
            connection.cancel()
        })
        try Task.checkCancellation()
        connected = true
    }

    public func close() {
        guard !closed else { return }
        closed = true
        connected = false
        connection.cancel()
        bufferedMessages.removeAll()
        bufferedEvents.removeAll()
        activeSessionID = nil
    }

    /// Sends a raw protocol request and returns its matching response.
    @discardableResult
    public func request(
        method: String,
        sessionID: String? = nil,
        params: PhoneJSONValue? = nil,
        id: String? = nil
    ) async throws -> PhoneEnvelope {
        guard !method.isEmpty else {
            throw PhoneControlClientError.unexpectedResponse("request method is empty")
        }
        return try await requestGate.withLock {
            try await self.performRequest(
                method: method,
                sessionID: sessionID,
                params: params,
                id: id
            )
        }
    }

    private func performRequest(
        method: String,
        sessionID: String?,
        params: PhoneJSONValue?,
        id: String?
    ) async throws -> PhoneEnvelope {
        try await connect()
        let requestID = try requestID(id)
        let request = PhoneEnvelope.request(
            id: requestID,
            method: method,
            sessionID: sessionID,
            params: params
        )
        do {
            try await send(codec.encode(request))
            while true {
                let message = try await nextMessage()
                if message.type == .event {
                    bufferedEvents.append(message)
                    continue
                }
                guard message.id == requestID else {
                    throw PhoneControlClientError.unexpectedResponse(
                        "response id \(message.id ?? "<missing>") did not match \(requestID)"
                    )
                }
                if message.type == .error {
                    guard let error = message.error else {
                        throw PhoneControlClientError.malformedResponse("error response omitted its payload")
                    }
                    throw PhoneControlClientError.remote(error)
                }
                guard message.type == .response else {
                    throw PhoneControlClientError.unexpectedResponse(
                        "message \(message.type.rawValue) is not a response"
                    )
                }
                return message
            }
        } catch let error as PhoneControlClientError {
            throw error
        } catch let error as PhoneWireCodecError {
            throw PhoneControlClientError.malformedResponse(String(describing: error))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw PhoneControlClientError.transport(String(describing: error))
        }
    }

    public func listDevices() async throws -> [PhoneDevice] {
        let response = try await request(method: "device.list")
        guard let result = response.result else {
            throw PhoneControlClientError.malformedResponse("device.list omitted result")
        }
        do {
            return try result.decode([PhoneDevice].self)
        } catch {
            throw PhoneControlClientError.malformedResponse("device.list returned an invalid device list")
        }
    }

    public func openSession() async throws -> PhoneSessionInfo {
        let response = try await request(method: "session.open")
        guard let sessionID = response.sessionID, !sessionID.isEmpty,
              let result = response.result else {
            throw PhoneControlClientError.malformedResponse("session.open omitted session details")
        }
        do {
            let object = try result.decode([String: PhoneJSONValue].self)
            guard let deviceValue = object["device"],
                  let capabilitiesValue = object["capabilities"] else {
                throw PhoneControlClientError.malformedResponse("session.open omitted device capabilities")
            }
            let device = try deviceValue.decode(PhoneDevice.self)
            let capabilities = try capabilitiesValue.decode(PhoneCapabilities.self)
            let info = PhoneSessionInfo(
                sessionID: sessionID,
                device: device,
                capabilities: capabilities
            )
            activeSessionID = sessionID
            return info
        } catch let error as PhoneControlClientError {
            throw error
        } catch {
            throw PhoneControlClientError.malformedResponse("session.open returned invalid session details")
        }
    }

    public func snapshot(sessionID: String? = nil) async throws -> PhoneScreenFrame {
        let response = try await request(
            method: "screen.snapshot",
            sessionID: try sessionIDOrActive(sessionID)
        )
        guard let result = response.result else {
            throw PhoneControlClientError.malformedResponse("screen.snapshot omitted its frame")
        }
        do {
            return try result.decode(PhoneScreenFrame.self)
        } catch {
            throw PhoneControlClientError.malformedResponse("screen.snapshot returned an invalid frame")
        }
    }

    public func accessibilityTree(sessionID: String? = nil) async throws -> PhoneUIElement? {
        let response = try await request(
            method: "ui.snapshot",
            sessionID: try sessionIDOrActive(sessionID)
        )
        guard let result = response.result else {
            throw PhoneControlClientError.malformedResponse("ui.snapshot omitted its tree")
        }
        if case .null = result { return nil }
        do {
            return try result.decode(PhoneUIElement.self)
        } catch {
            throw PhoneControlClientError.malformedResponse("ui.snapshot returned an invalid tree")
        }
    }

    public func perform(
        _ action: PhoneActionRequest,
        sessionID: String? = nil
    ) async throws -> PhoneActionReceipt {
        let response = try await request(
            method: "action.\(action.kind.rawValue)",
            sessionID: try sessionIDOrActive(sessionID),
            params: actionParams(action)
        )
        guard let result = response.result else {
            throw PhoneControlClientError.malformedResponse("action response omitted its receipt")
        }
        do {
            return try result.decode(PhoneActionReceipt.self)
        } catch {
            throw PhoneControlClientError.malformedResponse("action response returned an invalid receipt")
        }
    }

    public func closeSession(sessionID: String? = nil) async throws {
        let requestedSessionID = try sessionIDOrActive(sessionID)
        _ = try await request(method: "session.close", sessionID: requestedSessionID)
        if activeSessionID == requestedSessionID {
            activeSessionID = nil
        }
    }

    /// Returns events observed since the previous call.
    public func drainEvents() -> [PhoneEnvelope] {
        defer { bufferedEvents.removeAll() }
        return bufferedEvents
    }

    /// Waits for the next server event, retaining unrelated events for
    /// drainEvents(). This is useful when a caller wants proof that an input
    /// action's change notification crossed the transport.
    public func nextEvent() async throws -> PhoneEnvelope {
        try await requestGate.withLock {
            try await self.waitForNextEvent()
        }
    }

    private func waitForNextEvent() async throws -> PhoneEnvelope {
        if let event = bufferedEvents.first {
            bufferedEvents.removeFirst()
            return event
        }
        while true {
            let message = try await nextMessage()
            if message.type == .event {
                return message
            }
            bufferedMessages.insert(message, at: 0)
            throw PhoneControlClientError.unexpectedResponse(
                "received a non-event while waiting for an event"
            )
        }
    }

    private func requestID(_ requested: String?) throws -> String {
        if let requested {
            guard !requested.isEmpty else {
                throw PhoneControlClientError.unexpectedResponse("request id is empty")
            }
            return requested
        }
        requestCounter &+= 1
        return "client-\(requestCounter)"
    }

    private func sessionIDOrActive(_ requested: String?) throws -> String {
        guard let sessionID = requested ?? activeSessionID, !sessionID.isEmpty else {
            throw PhoneControlClientError.noSession
        }
        return sessionID
    }

    private func actionParams(_ action: PhoneActionRequest) -> PhoneJSONValue {
        var values: [String: PhoneJSONValue] = [
            "action_id": .string(action.actionID),
        ]
        if let screenSequence = action.screenSequence {
            values["screen_seq"] = .number(Double(screenSequence))
        }
        if let point = action.point {
            values["point"] = .object([
                "x": .number(point.x),
                "y": .number(point.y),
            ])
        }
        if let endPoint = action.endPoint {
            values["end_point"] = .object([
                "x": .number(endPoint.x),
                "y": .number(endPoint.y),
            ])
        }
        if let duration = action.durationMilliseconds {
            values["duration_ms"] = .number(Double(duration))
        }
        if let text = action.text { values["text"] = .string(text) }
        if let button = action.button { values["button"] = .string(button) }
        return .object(values)
    }

    private func send(_ data: Data) async throws {
        guard connected, !closed else { throw PhoneControlClientError.connectionClosed }
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                connection.send(content: data, completion: .contentProcessed { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                })
            }
        }, onCancel: {
            connection.cancel()
        })
    }

    private func nextMessage() async throws -> PhoneEnvelope {
        if !bufferedMessages.isEmpty {
            return bufferedMessages.removeFirst()
        }
        while true {
            let data = try await receiveChunk()
            let messages = try decoder.append(data)
            if !messages.isEmpty {
                bufferedMessages.append(contentsOf: messages)
                return bufferedMessages.removeFirst()
            }
        }
    }

    private func receiveChunk() async throws -> Data {
        guard connected, !closed else { throw PhoneControlClientError.connectionClosed }
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Data, Error>) in
                connection.receive(
                    minimumIncompleteLength: 1,
                    maximumLength: PhoneProtocol.maxResponseLineBytes
                ) { data, _, isComplete, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else if let data, !data.isEmpty {
                        continuation.resume(returning: data)
                    } else if isComplete {
                        continuation.resume(throwing: PhoneControlClientError.connectionClosed)
                    } else {
                        continuation.resume(throwing: PhoneControlClientError.transport("empty TCP read"))
                    }
                }
            }
        }, onCancel: {
            connection.cancel()
        })
    }
}

private final class ThrowingContinuationGate<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var result: Result<Value, Error>?
    private var hasResult = false

    func install(_ continuation: CheckedContinuation<Value, Error>) {
        lock.lock()
        if let result {
            lock.unlock()
            continuation.resume(with: result)
        } else {
            self.continuation = continuation
            lock.unlock()
        }
    }

    func resume(_ result: Result<Value, Error>) {
        lock.lock()
        guard !hasResult else {
            lock.unlock()
            return
        }
        hasResult = true
        self.result = result
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}

private actor PhoneRequestGate {
    private var locked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func withLock<Value: Sendable>(
        _ operation: @Sendable () async throws -> Value
    ) async rethrows -> Value {
        await acquire()
        defer { release() }
        return try await operation()
    }

    private func acquire() async {
        if !locked {
            locked = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    private func release() {
        if let waiter = waiters.first {
            waiters.removeFirst()
            waiter.resume()
        } else {
            locked = false
        }
    }
}

#endif
