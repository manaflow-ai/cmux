public import CMUXMobileCore
public import Foundation
@preconcurrency public import Network

/// A stable classification of Network.framework connection failures.
public enum CmxConnectFailureKind: Sendable, Equatable {
    case connectionRefused
    case hostUnreachable
    case timedOut
    case permissionDenied
    case dnsFailed
    case secureChannelFailed
    case generic
}

/// Errors raised by the route-neutral Network.framework byte transport.
public enum CmxNetworkByteTransportError: Error, Equatable, Sendable {
    case emptyHost
    case invalidPort(Int)
    case invalidMaximumReceiveLength(Int)
    case unsupportedRouteKind(CmxAttachTransportKind)
    case unsupportedEndpoint(CmxAttachEndpoint)
    case authorizationIntentRequired
    case unsupportedAuthorizationMode(CmxTransportAuthorizationMode)
    case tailscaleAuthorizationUnavailable
    case notConnected
    case alreadyClosed
    case receiveAlreadyInProgress
    case sendAlreadyInProgress
    case connectionTimedOut
    case connectionFailed(String, CmxConnectFailureKind)
    case receiveFailed(String)
    case sendFailed(String)
    case receiveBufferLimitReached
    case invalidFrame(String)
}

/// A single actor-owned TCP byte stream.
///
/// The transport deliberately knows nothing about VPN providers, peer
/// discovery, or application authentication. Route normalization happens at
/// the factory boundary, and bearer/admission credentials stay in the RPC
/// protocol. One actor owns the native connection, one reader, and a FIFO
/// writer, which removes the independent Iroh/Tailscale lifecycle owners that
/// previously raced each other.
public actor CmxNetworkByteTransport: CmxByteTransport {
    public static let defaultMaximumReceiveLength = 64 * 1024
    public static let defaultConnectTimeoutNanoseconds: UInt64 = 15 * 1_000_000_000
    public static let defaultMaximumBufferedReceiveBytes = 512 * 1024

    private enum State {
        case idle
        case connecting
        case ready
        case failed(CmxNetworkByteTransportError)
        case closed
    }

    private struct PendingSend {
        let id: UUID
        let data: Data
        let continuation: CheckedContinuation<Void, any Error>
        var cancelled = false
    }

    private let connection: NWConnection
    private let callbackQueue: DispatchQueue
    private let maximumReceiveLength: Int
    private let maximumBufferedReceiveBytes: Int
    private let connectTimeoutNanoseconds: UInt64
    private var state: State = .idle
    private var connectWaiters: [UUID: CheckedContinuation<Void, any Error>] = [:]
    private var receiveWaiter: (id: UUID, continuation: CheckedContinuation<Data?, any Error>)?
    private var receiveBuffer: [Data] = []
    private var bufferedReceiveBytes = 0
    private var receiveReadOutstanding = false
    private var sendQueue: [PendingSend] = []
    private var sendInFlight = false
    private var activeSend: PendingSend?
    private var connectTimeoutTask: Task<Void, Never>?
    private var remoteDidClose = false
    private var continuityGeneration: UInt64 = 0

    public init(
        host: String,
        port: Int,
        maximumReceiveLength: Int = CmxNetworkByteTransport.defaultMaximumReceiveLength,
        maximumBufferedReceiveBytes: Int = CmxNetworkByteTransport.defaultMaximumBufferedReceiveBytes,
        connectTimeoutNanoseconds: UInt64 = CmxNetworkByteTransport.defaultConnectTimeoutNanoseconds
    ) throws {
        let normalizedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedHost.isEmpty else { throw CmxNetworkByteTransportError.emptyHost }
        guard (1 ... 65_535).contains(port) else {
            throw CmxNetworkByteTransportError.invalidPort(port)
        }
        guard maximumReceiveLength > 0 else {
            throw CmxNetworkByteTransportError.invalidMaximumReceiveLength(maximumReceiveLength)
        }
        guard maximumBufferedReceiveBytes >= maximumReceiveLength else {
            throw CmxNetworkByteTransportError.receiveBufferLimitReached
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
            label: "dev.cmux.mobile.stable-network-transport.\(UUID().uuidString)"
        )
        self.maximumReceiveLength = maximumReceiveLength
        self.maximumBufferedReceiveBytes = maximumBufferedReceiveBytes
        self.connectTimeoutNanoseconds = max(1, connectTimeoutNanoseconds)
    }

    public init(
        route: CmxAttachRoute,
        maximumReceiveLength: Int = CmxNetworkByteTransport.defaultMaximumReceiveLength,
        maximumBufferedReceiveBytes: Int = CmxNetworkByteTransport.defaultMaximumBufferedReceiveBytes,
        connectTimeoutNanoseconds: UInt64 = CmxNetworkByteTransport.defaultConnectTimeoutNanoseconds
    ) throws {
        let stableRoute = try route.normalizedForStableTransport()
        guard stableRoute.kind == .tcp || stableRoute.kind == .debugLoopback else {
            throw CmxNetworkByteTransportError.unsupportedRouteKind(stableRoute.kind)
        }
        guard case let .hostPort(host, port) = stableRoute.endpoint else {
            throw CmxNetworkByteTransportError.unsupportedEndpoint(stableRoute.endpoint)
        }
        guard maximumReceiveLength > 0 else {
            throw CmxNetworkByteTransportError.invalidMaximumReceiveLength(maximumReceiveLength)
        }
        guard maximumBufferedReceiveBytes >= maximumReceiveLength else {
            throw CmxNetworkByteTransportError.receiveBufferLimitReached
        }
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            throw CmxNetworkByteTransportError.invalidPort(port)
        }
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.noDelay = true
        let parameters = NWParameters(tls: nil, tcp: tcpOptions)
        connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: nwPort,
            using: parameters
        )
        callbackQueue = DispatchQueue(
            label: "dev.cmux.mobile.stable-network-transport.\(UUID().uuidString)"
        )
        self.maximumReceiveLength = maximumReceiveLength
        self.maximumBufferedReceiveBytes = maximumBufferedReceiveBytes
        self.connectTimeoutNanoseconds = max(1, connectTimeoutNanoseconds)
    }

    /// Creates a transport around an accepted host-side connection.
    public init(acceptedConnection: NWConnection) {
        connection = acceptedConnection
        callbackQueue = DispatchQueue(
            label: "dev.cmux.mobile.stable-accepted-network-transport.\(UUID().uuidString)"
        )
        maximumReceiveLength = Self.defaultMaximumReceiveLength
        maximumBufferedReceiveBytes = Self.defaultMaximumBufferedReceiveBytes
        connectTimeoutNanoseconds = Self.defaultConnectTimeoutNanoseconds
    }

    public init(
        acceptedConnection: NWConnection,
        maximumReceiveLength: Int,
        connectTimeoutNanoseconds: UInt64 = CmxNetworkByteTransport.defaultConnectTimeoutNanoseconds
    ) throws {
        guard maximumReceiveLength > 0 else {
            throw CmxNetworkByteTransportError.invalidMaximumReceiveLength(maximumReceiveLength)
        }
        connection = acceptedConnection
        callbackQueue = DispatchQueue(
            label: "dev.cmux.mobile.stable-accepted-network-transport.\(UUID().uuidString)"
        )
        self.maximumReceiveLength = maximumReceiveLength
        maximumBufferedReceiveBytes = max(
            Self.defaultMaximumBufferedReceiveBytes,
            maximumReceiveLength
        )
        self.connectTimeoutNanoseconds = max(1, connectTimeoutNanoseconds)
    }

    public func connect() async throws {
        try Task.checkCancellation()
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                beginConnect(id: id, continuation: continuation)
            }
        } onCancel: {
            Task { await self.cancelConnect(id: id) }
        }
    }

    public func receive() async throws -> Data? {
        try Task.checkCancellation()
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                beginReceive(id: id, continuation: continuation)
            }
        } onCancel: {
            Task { await self.cancelReceive(id: id) }
        }
    }

    public func send(_ data: Data) async throws {
        guard !data.isEmpty else { return }
        try Task.checkCancellation()
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                beginSend(id: id, data: data, continuation: continuation)
            }
        } onCancel: {
            Task { await self.cancelSend(id: id) }
        }
    }

    public func close() async {
        close(with: CmxNetworkByteTransportError.alreadyClosed)
    }

    /// Compatibility hook for the removed provider-specific write gate. The
    /// stable transport has one generic authorization boundary owned by its
    /// caller, so this helper simply preserves the ordering guarantee.
    @available(*, deprecated, message: "Authorize at the RPC boundary")
    public func performAuthorizedWrite(
        authorization: () async throws -> Void,
        beginWrite: () -> Void
    ) async rethrows {
        try await authorization()
        beginWrite()
    }

    private func beginConnect(
        id: UUID,
        continuation: CheckedContinuation<Void, any Error>
    ) {
        switch state {
        case .idle:
            connectWaiters[id] = continuation
            state = .connecting
            installCallbacks()
            scheduleConnectTimeout()
            connection.start(queue: callbackQueue)
        case .connecting:
            connectWaiters[id] = continuation
        case .ready:
            continuation.resume()
        case let .failed(error):
            continuation.resume(throwing: error)
        case .closed:
            continuation.resume(throwing: CmxNetworkByteTransportError.alreadyClosed)
        }
    }

    private func installCallbacks() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            let event = CmxNetworkConnectionEvent(state)
            Task { await self.handleConnectionEvent(event) }
        }
    }

    private func handleConnectionEvent(_ event: CmxNetworkConnectionEvent) {
        guard !isTerminal else { return }
        switch event {
        case .ready:
            cancelConnectTimeout()
            state = .ready
            continuityGeneration &+= 1
            let waiters = connectWaiters
            connectWaiters.removeAll()
            for waiter in waiters.values { waiter.resume() }
        case let .waiting(description, kind):
            guard case .connecting = state, waitingKindFailsConnect(kind) else { return }
            fail(.connectionFailed(description, kind))
        case let .failed(description, kind):
            fail(.connectionFailed(description, kind))
        case .cancelled:
            guard !isTerminal else { return }
            fail(.alreadyClosed)
        case .other:
            break
        }
    }

    private func beginReceive(
        id: UUID,
        continuation: CheckedContinuation<Data?, any Error>
    ) {
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
            let data = receiveBuffer.removeFirst()
            bufferedReceiveBytes -= data.count
            continuation.resume(returning: data)
            return
        }
        if remoteDidClose {
            continuation.resume(returning: nil)
            return
        }
        guard receiveWaiter == nil else {
            continuation.resume(throwing: CmxNetworkByteTransportError.receiveAlreadyInProgress)
            return
        }
        receiveWaiter = (id, continuation)
        issueReceiveIfNeeded()
    }

    private func issueReceiveIfNeeded() {
        guard !receiveReadOutstanding, !remoteDidClose, !isTerminal else { return }
        receiveReadOutstanding = true
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: maximumReceiveLength
        ) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            let description = error.map(\.cmxUserFacingDescription)
            Task {
                await self.handleReceive(
                    data: data,
                    isComplete: isComplete,
                    errorDescription: description
                )
            }
        }
    }

    private func handleReceive(data: Data?, isComplete: Bool, errorDescription: String?) {
        receiveReadOutstanding = false
        guard !isTerminal else { return }
        if let errorDescription {
            fail(.receiveFailed(errorDescription))
            return
        }
        if let data, !data.isEmpty {
            if let waiter = receiveWaiter {
                receiveWaiter = nil
                waiter.continuation.resume(returning: data)
            } else if bufferedReceiveBytes + data.count <= maximumBufferedReceiveBytes {
                receiveBuffer.append(data)
                bufferedReceiveBytes += data.count
            } else {
                fail(.receiveBufferLimitReached)
                return
            }
            if isComplete { remoteDidClose = true }
            return
        }
        if isComplete {
            remoteDidClose = true
            receiveWaiter?.continuation.resume(returning: nil)
            receiveWaiter = nil
            return
        }
        issueReceiveIfNeeded()
    }

    private func beginSend(
        id: UUID,
        data: Data,
        continuation: CheckedContinuation<Void, any Error>
    ) {
        switch state {
        case .ready:
            sendQueue.append(PendingSend(id: id, data: data, continuation: continuation))
            processNextSend()
        case let .failed(error):
            continuation.resume(throwing: error)
        case .closed:
            continuation.resume(throwing: CmxNetworkByteTransportError.alreadyClosed)
        case .idle, .connecting:
            continuation.resume(throwing: CmxNetworkByteTransportError.notConnected)
        }
    }

    private func processNextSend() {
        guard !sendInFlight, !sendQueue.isEmpty, !isTerminal else { return }
        sendInFlight = true
        let operation = sendQueue.removeFirst()
        activeSend = operation
        connection.send(
            content: operation.data,
            contentContext: .defaultMessage,
            isComplete: false,
            completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                let description = error.map(\.cmxUserFacingDescription)
                Task { await self.handleSend(id: operation.id, errorDescription: description) }
            }
        )
    }

    private func handleSend(id: UUID, errorDescription: String?) {
        sendInFlight = false
        guard !isTerminal else { return }
        guard let operation = activeSend, operation.id == id else {
            // The operation was removed by cancellation while Network.framework
            // was still processing it. Its completion is intentionally ignored.
            processNextSend()
            return
        }
        activeSend = nil
        if let errorDescription {
            let error = CmxNetworkByteTransportError.sendFailed(errorDescription)
            // Detach the active operation before failing the transport so the
            // common failure path only settles queued operations. This keeps
            // the single-resume invariant for the callback that owns `id`.
            if !operation.cancelled {
                operation.continuation.resume(throwing: error)
            }
            fail(error)
        } else if !operation.cancelled {
            operation.continuation.resume()
        }
        processNextSend()
    }

    private func cancelConnect(id: UUID) {
        guard let continuation = connectWaiters.removeValue(forKey: id) else { return }
        continuation.resume(throwing: CancellationError())
        if connectWaiters.isEmpty, case .connecting = state {
            close(with: CancellationError())
        }
    }

    private func cancelReceive(id: UUID) {
        guard let waiter = receiveWaiter, waiter.id == id else { return }
        receiveWaiter = nil
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func cancelSend(id: UUID) {
        if var operation = activeSend, operation.id == id {
            operation.cancelled = true
            activeSend = operation
            operation.continuation.resume(throwing: CancellationError())
            return
        }
        guard let index = sendQueue.firstIndex(where: { $0.id == id }) else { return }
        let operation = sendQueue.remove(at: index)
        operation.continuation.resume(throwing: CancellationError())
        if index == 0, !sendInFlight { processNextSend() }
    }

    private func fail(_ error: CmxNetworkByteTransportError) {
        guard !isTerminal else { return }
        cancelConnectTimeout()
        state = .failed(error)
        connection.stateUpdateHandler = nil
        connection.cancel()
        resumeConnectWaiters(throwing: error)
        receiveWaiter?.continuation.resume(throwing: error)
        receiveWaiter = nil
        resumeSendQueue(throwing: error)
    }

    private func close(with error: any Error) {
        guard !isTerminal else { return }
        cancelConnectTimeout()
        state = .closed
        connection.stateUpdateHandler = nil
        connection.cancel()
        resumeConnectWaiters(throwing: error)
        receiveWaiter?.continuation.resume(returning: nil)
        receiveWaiter = nil
        resumeSendQueue(throwing: error)
        receiveBuffer.removeAll()
        bufferedReceiveBytes = 0
        continuityGeneration &+= 1
    }

    private func resumeConnectWaiters(throwing error: any Error) {
        let waiters = connectWaiters
        connectWaiters.removeAll()
        for waiter in waiters.values { waiter.resume(throwing: error) }
    }

    private func resumeSendQueue(throwing error: any Error) {
        let queued = sendQueue
        sendQueue.removeAll()
        sendInFlight = false
        if let activeSend {
            if !activeSend.cancelled {
                activeSend.continuation.resume(throwing: error)
            }
            self.activeSend = nil
        }
        for operation in queued { operation.continuation.resume(throwing: error) }
    }

    private func scheduleConnectTimeout() {
        connectTimeoutTask?.cancel()
        let duration = connectTimeoutNanoseconds
        connectTimeoutTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: duration)
            } catch {
                return
            }
            await self?.handleConnectTimeout()
        }
    }

    private func cancelConnectTimeout() {
        connectTimeoutTask?.cancel()
        connectTimeoutTask = nil
    }

    private func handleConnectTimeout() {
        guard case .connecting = state else { return }
        fail(.connectionTimedOut)
    }

    private var isTerminal: Bool {
        switch state {
        case .failed, .closed: return true
        case .idle, .connecting, .ready: return false
        }
    }

    /// Returns a process-local generation for diagnostics and continuity checks.
    public func transportContinuityID() async -> UInt64? {
        guard case .ready = state else { return nil }
        return continuityGeneration
    }
}

private func waitingKindFailsConnect(_ kind: CmxConnectFailureKind) -> Bool {
    switch kind {
    case .connectionRefused, .hostUnreachable, .permissionDenied, .dnsFailed, .secureChannelFailed:
        return true
    case .timedOut, .generic:
        return false
    }
}
