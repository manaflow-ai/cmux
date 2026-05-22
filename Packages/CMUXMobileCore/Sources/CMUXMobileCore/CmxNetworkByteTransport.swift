import Dispatch
import Foundation
@preconcurrency import Network

public enum CmxNetworkByteTransportError: Error, Equatable, Sendable {
    case emptyHost
    case invalidPort(Int)
    case invalidMaximumReceiveLength(Int)
    case unsupportedRouteKind(CmxAttachTransportKind)
    case unsupportedEndpoint(CmxAttachEndpoint)
    case notConnected
    case alreadyClosed
    case receiveAlreadyInProgress
    case sendAlreadyInProgress
    case connectionTimedOut
    case connectionFailed(String)
    case receiveFailed(String)
    case sendFailed(String)
}

public struct CmxNetworkByteTransportFactory: CmxRouteAwareByteTransportFactory {
    public var supportedKinds: [CmxAttachTransportKind]
    public var maximumReceiveLength: Int

    public init(
        supportedKinds: [CmxAttachTransportKind] = [.tailscale, .debugLoopback],
        maximumReceiveLength: Int = CmxNetworkByteTransport.defaultMaximumReceiveLength
    ) {
        self.supportedKinds = supportedKinds
        self.maximumReceiveLength = maximumReceiveLength
    }

    public func makeTransport(for route: CmxAttachRoute) throws -> any CmxByteTransport {
        try route.validate()
        guard supportedKinds.contains(route.kind) else {
            throw CmxNetworkByteTransportError.unsupportedRouteKind(route.kind)
        }
        guard case let .hostPort(host, port) = route.endpoint else {
            throw CmxNetworkByteTransportError.unsupportedEndpoint(route.endpoint)
        }
        return try CmxNetworkByteTransport(
            host: host,
            port: port,
            maximumReceiveLength: maximumReceiveLength
        )
    }
}

public actor CmxNetworkByteTransport: CmxByteTransport {
    public static let defaultMaximumReceiveLength = 64 * 1024
    public static let defaultConnectTimeoutNanoseconds: UInt64 = 15 * 1_000_000_000

    private enum TransportState {
        case idle
        case connecting
        case ready
        case failed(CmxNetworkByteTransportError)
        case closed
    }

    private let connection: NWConnection
    // Network.framework requires a callback queue; state changes re-enter this actor.
    private let callbackQueue: DispatchQueue
    private let maximumReceiveLength: Int
    private let connectTimeoutNanoseconds: UInt64
    private var state: TransportState = .idle
    private var connectContinuations: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var receiveContinuation: (id: UUID, continuation: CheckedContinuation<Data?, Error>)?
    private var receiveInFlightOperationID: UUID?
    private var receiveBuffer: [Data] = []
    private var sendContinuation: (id: UUID, continuation: CheckedContinuation<Void, Error>)?
    private var cancelledOperationIDs: Set<UUID> = []
    private var connectTimeoutTimer: DispatchSourceTimer?
    private var remoteDidClose = false

    public init(
        host: String,
        port: Int,
        maximumReceiveLength: Int = CmxNetworkByteTransport.defaultMaximumReceiveLength,
        connectTimeoutNanoseconds: UInt64 = CmxNetworkByteTransport.defaultConnectTimeoutNanoseconds
    ) throws {
        let normalizedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedHost.isEmpty else {
            throw CmxNetworkByteTransportError.emptyHost
        }
        guard (1...65535).contains(port) else {
            throw CmxNetworkByteTransportError.invalidPort(port)
        }
        guard maximumReceiveLength > 0 else {
            throw CmxNetworkByteTransportError.invalidMaximumReceiveLength(maximumReceiveLength)
        }
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            throw CmxNetworkByteTransportError.invalidPort(port)
        }

        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.noDelay = true
        let parameters = NWParameters(tls: nil, tcp: tcpOptions)
        connection = NWConnection(
            host: NWEndpoint.Host(normalizedHost),
            port: nwPort,
            using: parameters
        )
        callbackQueue = DispatchQueue(
            label: "dev.cmux.mobile.network-byte-transport.\(UUID().uuidString)"
        )
        self.maximumReceiveLength = maximumReceiveLength
        self.connectTimeoutNanoseconds = max(1, connectTimeoutNanoseconds)
    }

    public init(
        route: CmxAttachRoute,
        maximumReceiveLength: Int = CmxNetworkByteTransport.defaultMaximumReceiveLength,
        connectTimeoutNanoseconds: UInt64 = CmxNetworkByteTransport.defaultConnectTimeoutNanoseconds
    ) throws {
        try route.validate()
        guard case let .hostPort(host, port) = route.endpoint else {
            throw CmxNetworkByteTransportError.unsupportedEndpoint(route.endpoint)
        }
        try self.init(
            host: host,
            port: port,
            maximumReceiveLength: maximumReceiveLength,
            connectTimeoutNanoseconds: connectTimeoutNanoseconds
        )
    }

    public func connect() async throws {
        try Task.checkCancellation()
        let operationID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                startConnect(operationID: operationID, continuation: continuation)
            }
        } onCancel: {
            Task { await self.cancelConnect(operationID: operationID) }
        }
    }

    public func receive() async throws -> Data? {
        try Task.checkCancellation()
        let operationID = UUID()
        return try await withTaskCancellationHandler {
            return try await withCheckedThrowingContinuation { continuation in
                startReceive(operationID: operationID, continuation: continuation)
            }
        } onCancel: {
            Task { await self.cancelReceive(operationID: operationID) }
        }
    }

    public func send(_ data: Data) async throws {
        guard !data.isEmpty else {
            return
        }
        try Task.checkCancellation()
        let operationID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                startSend(data, operationID: operationID, continuation: continuation)
            }
        } onCancel: {
            Task { await self.cancelSend(operationID: operationID) }
        }
    }

    public func close() async {
        close(
            pendingError: CmxNetworkByteTransportError.alreadyClosed,
            resumeReceiveWithError: false
        )
    }

    private func startConnect(
        operationID: UUID,
        continuation: CheckedContinuation<Void, Error>
    ) {
        guard !consumeCancelledOperation(operationID) else {
            continuation.resume(throwing: CancellationError())
            return
        }
        switch state {
        case .idle:
            connectContinuations[operationID] = continuation
            state = .connecting
            scheduleConnectTimeout()
            connection.stateUpdateHandler = { [weak self] state in
                let event = CmxNetworkConnectionEvent(state)
                guard let self else {
                    return
                }
                Task { await self.handleConnectionEvent(event) }
            }
            connection.start(queue: callbackQueue)
        case .connecting:
            connectContinuations[operationID] = continuation
        case .ready:
            continuation.resume()
        case let .failed(error):
            continuation.resume(throwing: error)
        case .closed:
            continuation.resume(throwing: CmxNetworkByteTransportError.alreadyClosed)
        }
    }

    private func handleConnectionEvent(_ event: CmxNetworkConnectionEvent) {
        switch event {
        case .ready:
            guard !isTerminal else {
                return
            }
            cancelConnectTimeout()
            state = .ready
            resumeConnectContinuations()
        case .waiting:
            break
        case let .failed(errorDescription):
            failTransport(.connectionFailed(errorDescription))
        case .cancelled:
            switch state {
            case .closed, .failed:
                break
            case .idle, .connecting, .ready:
                close(
                    pendingError: CmxNetworkByteTransportError.alreadyClosed,
                    resumeReceiveWithError: false
                )
            }
        case .other:
            break
        }
    }

    private func startReceive(
        operationID: UUID,
        continuation: CheckedContinuation<Data?, Error>
    ) {
        guard !consumeCancelledOperation(operationID) else {
            continuation.resume(throwing: CancellationError())
            return
        }
        switch state {
        case .ready:
            break
        case let .failed(error):
            continuation.resume(throwing: error)
            return
        case .closed:
            continuation.resume(returning: nil)
            return
        case .idle, .connecting:
            continuation.resume(throwing: CmxNetworkByteTransportError.notConnected)
            return
        }

        if !receiveBuffer.isEmpty {
            continuation.resume(returning: receiveBuffer.removeFirst())
            return
        }
        guard !remoteDidClose else {
            continuation.resume(returning: nil)
            return
        }
        guard receiveContinuation == nil else {
            continuation.resume(throwing: CmxNetworkByteTransportError.receiveAlreadyInProgress)
            return
        }

        receiveContinuation = (operationID, continuation)
        if receiveInFlightOperationID == nil {
            issueReceive(operationID: operationID)
        }
    }

    private func issueReceive(operationID: UUID) {
        receiveInFlightOperationID = operationID
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: maximumReceiveLength
        ) { [weak self] data, _, isComplete, error in
            let errorDescription = error.map(cmxNetworkErrorDescription)
            guard let self else {
                return
            }
            Task {
                await self.handleReceive(
                    operationID: operationID,
                    data: data,
                    isComplete: isComplete,
                    errorDescription: errorDescription
                )
            }
        }
    }

    private func handleReceive(
        operationID: UUID,
        data: Data?,
        isComplete: Bool,
        errorDescription: String?
    ) {
        _ = consumeCancelledOperation(operationID)
        if receiveInFlightOperationID == operationID {
            receiveInFlightOperationID = nil
        }
        guard !isTerminal else {
            return
        }

        if let errorDescription {
            let error = CmxNetworkByteTransportError.receiveFailed(errorDescription)
            failTransport(error)
            return
        }

        if let data, !data.isEmpty {
            remoteDidClose = isComplete
            deliverReceivedData(data)
            return
        }

        if isComplete {
            remoteDidClose = true
            deliverEndOfStream()
            return
        }

        if let pending = receiveContinuation {
            issueReceive(operationID: pending.id)
        }
    }

    private func deliverReceivedData(_ data: Data) {
        guard let pending = receiveContinuation else {
            receiveBuffer.append(data)
            return
        }
        receiveContinuation = nil
        pending.continuation.resume(returning: data)
    }

    private func deliverEndOfStream() {
        guard let pending = receiveContinuation else {
            return
        }
        receiveContinuation = nil
        pending.continuation.resume(returning: nil)
    }

    private func startSend(
        _ data: Data,
        operationID: UUID,
        continuation: CheckedContinuation<Void, Error>
    ) {
        guard !consumeCancelledOperation(operationID) else {
            continuation.resume(throwing: CancellationError())
            return
        }
        switch state {
        case .ready:
            break
        case let .failed(error):
            continuation.resume(throwing: error)
            return
        case .closed:
            continuation.resume(throwing: CmxNetworkByteTransportError.alreadyClosed)
            return
        case .idle, .connecting:
            continuation.resume(throwing: CmxNetworkByteTransportError.notConnected)
            return
        }

        guard sendContinuation == nil else {
            continuation.resume(throwing: CmxNetworkByteTransportError.sendAlreadyInProgress)
            return
        }

        sendContinuation = (operationID, continuation)
        connection.send(
            content: data,
            contentContext: .defaultMessage,
            isComplete: false,
            completion: .contentProcessed { [weak self] error in
                let errorDescription = error.map(cmxNetworkErrorDescription)
                guard let self else {
                    return
                }
                Task {
                    await self.handleSend(
                        operationID: operationID,
                        errorDescription: errorDescription
                    )
                }
            }
        )
    }

    private func handleSend(operationID: UUID, errorDescription: String?) {
        _ = consumeCancelledOperation(operationID)
        guard let pending = sendContinuation, pending.id == operationID else {
            if let errorDescription {
                failTransport(.sendFailed(errorDescription))
            }
            return
        }
        sendContinuation = nil

        if let errorDescription {
            let error = CmxNetworkByteTransportError.sendFailed(errorDescription)
            failTransport(error)
            pending.continuation.resume(throwing: error)
            return
        }

        pending.continuation.resume()
    }

    private func failTransport(_ error: CmxNetworkByteTransportError) {
        guard !isTerminal else {
            return
        }
        cancelConnectTimeout()
        state = .failed(error)
        cancelledOperationIDs.removeAll()
        receiveBuffer.removeAll()
        receiveInFlightOperationID = nil
        connection.cancel()
        resumeConnectContinuations(throwing: error)
        resumeReceiveContinuation(throwing: error)
        resumeSendContinuation(throwing: error)
    }

    private func close(pendingError: Error, resumeReceiveWithError: Bool) {
        guard !isClosed else {
            return
        }
        cancelConnectTimeout()
        state = .closed
        cancelledOperationIDs.removeAll()
        receiveBuffer.removeAll()
        receiveInFlightOperationID = nil
        connection.stateUpdateHandler = nil
        connection.cancel()
        resumeConnectContinuations(throwing: pendingError)
        if resumeReceiveWithError {
            resumeReceiveContinuation(throwing: pendingError)
        } else {
            resumeReceiveContinuation(returning: nil)
        }
        resumeSendContinuation(throwing: pendingError)
    }

    private func cancelConnect(operationID: UUID) {
        if let continuation = connectContinuations.removeValue(forKey: operationID) {
            continuation.resume(throwing: CancellationError())
        } else {
            cancelledOperationIDs.insert(operationID)
        }
    }

    private func cancelReceive(operationID: UUID) {
        if let pending = receiveContinuation, pending.id == operationID {
            receiveContinuation = nil
            pending.continuation.resume(throwing: CancellationError())
        } else {
            cancelledOperationIDs.insert(operationID)
        }
    }

    private func cancelSend(operationID: UUID) {
        if let pending = sendContinuation, pending.id == operationID {
            sendContinuation = nil
            pending.continuation.resume(throwing: CancellationError())
            close(pendingError: CancellationError(), resumeReceiveWithError: true)
        } else {
            cancelledOperationIDs.insert(operationID)
        }
    }

    private func consumeCancelledOperation(_ operationID: UUID) -> Bool {
        cancelledOperationIDs.remove(operationID) != nil
    }

    private func scheduleConnectTimeout() {
        cancelConnectTimeout()
        let timer = DispatchSource.makeTimerSource(queue: callbackQueue)
        let timeout = min(connectTimeoutNanoseconds, UInt64(Int.max))
        timer.schedule(deadline: .now() + .nanoseconds(Int(timeout)))
        timer.setEventHandler { [weak self] in
            guard let self else {
                return
            }
            Task { await self.handleConnectTimeout() }
        }
        connectTimeoutTimer = timer
        timer.resume()
    }

    private func cancelConnectTimeout() {
        connectTimeoutTimer?.setEventHandler {}
        connectTimeoutTimer?.cancel()
        connectTimeoutTimer = nil
    }

    private func handleConnectTimeout() {
        guard case .connecting = state else {
            return
        }
        failTransport(.connectionTimedOut)
    }

    private var isTerminal: Bool {
        switch state {
        case .failed, .closed:
            return true
        case .idle, .connecting, .ready:
            return false
        }
    }

    private var isClosed: Bool {
        if case .closed = state {
            return true
        }
        return false
    }

    private func resumeConnectContinuations(throwing error: Error? = nil) {
        let continuations = connectContinuations.values
        connectContinuations.removeAll()
        for continuation in continuations {
            if let error {
                continuation.resume(throwing: error)
            } else {
                continuation.resume()
            }
        }
    }

    private func resumeReceiveContinuation(
        returning data: Data? = nil,
        throwing error: Error? = nil
    ) {
        guard let pending = receiveContinuation else {
            return
        }
        receiveContinuation = nil
        if let error {
            pending.continuation.resume(throwing: error)
        } else {
            pending.continuation.resume(returning: data)
        }
    }

    private func resumeSendContinuation(throwing error: Error) {
        guard let pending = sendContinuation else {
            return
        }
        sendContinuation = nil
        pending.continuation.resume(throwing: error)
    }
}

private enum CmxNetworkConnectionEvent: Sendable {
    case ready
    case waiting(String)
    case failed(String)
    case cancelled
    case other

    init(_ state: NWConnection.State) {
        switch state {
        case .ready:
            self = .ready
        case let .waiting(error):
            self = .waiting(cmxNetworkErrorDescription(error))
        case let .failed(error):
            self = .failed(cmxNetworkErrorDescription(error))
        case .cancelled:
            self = .cancelled
        case .setup, .preparing:
            self = .other
        @unknown default:
            self = .other
        }
    }
}

private func cmxNetworkErrorDescription(_ error: NWError) -> String {
    String(describing: error)
}
