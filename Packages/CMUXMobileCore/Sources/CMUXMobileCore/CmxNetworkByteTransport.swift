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
    private var state: TransportState = .idle
    private var connectContinuations: [CheckedContinuation<Void, Error>] = []
    private var receiveContinuation: CheckedContinuation<Data?, Error>?
    private var sendContinuation: CheckedContinuation<Void, Error>?
    private var remoteDidClose = false

    public init(
        host: String,
        port: Int,
        maximumReceiveLength: Int = CmxNetworkByteTransport.defaultMaximumReceiveLength
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

        connection = NWConnection(
            host: NWEndpoint.Host(normalizedHost),
            port: nwPort,
            using: .tcp
        )
        callbackQueue = DispatchQueue(
            label: "dev.cmux.mobile.network-byte-transport.\(UUID().uuidString)"
        )
        self.maximumReceiveLength = maximumReceiveLength
    }

    public init(
        route: CmxAttachRoute,
        maximumReceiveLength: Int = CmxNetworkByteTransport.defaultMaximumReceiveLength
    ) throws {
        try route.validate()
        guard case let .hostPort(host, port) = route.endpoint else {
            throw CmxNetworkByteTransportError.unsupportedEndpoint(route.endpoint)
        }
        try self.init(host: host, port: port, maximumReceiveLength: maximumReceiveLength)
    }

    public func connect() async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                startConnect(continuation)
            }
        } onCancel: {
            Task { await self.cancelForTaskCancellation() }
        }
    }

    public func receive() async throws -> Data? {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                startReceive(continuation)
            }
        } onCancel: {
            Task { await self.cancelForTaskCancellation() }
        }
    }

    public func send(_ data: Data) async throws {
        guard !data.isEmpty else {
            return
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                startSend(data, continuation: continuation)
            }
        } onCancel: {
            Task { await self.cancelForTaskCancellation() }
        }
    }

    public func close() async {
        close(
            pendingError: CmxNetworkByteTransportError.alreadyClosed,
            resumeReceiveWithError: false
        )
    }

    private func startConnect(_ continuation: CheckedContinuation<Void, Error>) {
        switch state {
        case .idle:
            connectContinuations.append(continuation)
            state = .connecting
            connection.stateUpdateHandler = { [weak self] state in
                let event = CmxNetworkConnectionEvent(state)
                guard let self else {
                    return
                }
                Task { await self.handleConnectionEvent(event) }
            }
            connection.start(queue: callbackQueue)
        case .connecting:
            connectContinuations.append(continuation)
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

    private func startReceive(_ continuation: CheckedContinuation<Data?, Error>) {
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

        guard !remoteDidClose else {
            continuation.resume(returning: nil)
            return
        }
        guard receiveContinuation == nil else {
            continuation.resume(throwing: CmxNetworkByteTransportError.receiveAlreadyInProgress)
            return
        }

        receiveContinuation = continuation
        issueReceive()
    }

    private func issueReceive() {
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
                    data: data,
                    isComplete: isComplete,
                    errorDescription: errorDescription
                )
            }
        }
    }

    private func handleReceive(
        data: Data?,
        isComplete: Bool,
        errorDescription: String?
    ) {
        guard let continuation = receiveContinuation else {
            return
        }

        if let errorDescription {
            receiveContinuation = nil
            let error = CmxNetworkByteTransportError.receiveFailed(errorDescription)
            failTransport(error)
            continuation.resume(throwing: error)
            return
        }

        if let data, !data.isEmpty {
            receiveContinuation = nil
            remoteDidClose = isComplete
            continuation.resume(returning: data)
            return
        }

        if isComplete {
            receiveContinuation = nil
            remoteDidClose = true
            continuation.resume(returning: nil)
            return
        }

        issueReceive()
    }

    private func startSend(
        _ data: Data,
        continuation: CheckedContinuation<Void, Error>
    ) {
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

        sendContinuation = continuation
        connection.send(
            content: data,
            contentContext: .defaultMessage,
            isComplete: false,
            completion: .contentProcessed { [weak self] error in
                let errorDescription = error.map(cmxNetworkErrorDescription)
                guard let self else {
                    return
                }
                Task { await self.handleSend(errorDescription: errorDescription) }
            }
        )
    }

    private func handleSend(errorDescription: String?) {
        guard let continuation = sendContinuation else {
            return
        }
        sendContinuation = nil

        if let errorDescription {
            let error = CmxNetworkByteTransportError.sendFailed(errorDescription)
            failTransport(error)
            continuation.resume(throwing: error)
            return
        }

        continuation.resume()
    }

    private func failTransport(_ error: CmxNetworkByteTransportError) {
        guard !isTerminal else {
            return
        }
        state = .failed(error)
        connection.cancel()
        resumeConnectContinuations(throwing: error)
        resumeReceiveContinuation(throwing: error)
        resumeSendContinuation(throwing: error)
    }

    private func close(pendingError: Error, resumeReceiveWithError: Bool) {
        guard !isClosed else {
            return
        }
        state = .closed
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

    private func cancelForTaskCancellation() {
        close(pendingError: CancellationError(), resumeReceiveWithError: true)
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
        let continuations = connectContinuations
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
        guard let continuation = receiveContinuation else {
            return
        }
        receiveContinuation = nil
        if let error {
            continuation.resume(throwing: error)
        } else {
            continuation.resume(returning: data)
        }
    }

    private func resumeSendContinuation(throwing error: Error) {
        guard let continuation = sendContinuation else {
            return
        }
        sendContinuation = nil
        continuation.resume(throwing: error)
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
