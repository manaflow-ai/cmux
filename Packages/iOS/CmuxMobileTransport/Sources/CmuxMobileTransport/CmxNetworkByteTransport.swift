public import CMUXMobileCore
public import Foundation
import Dispatch
@preconcurrency public import Network

/// Why a connection attempt failed, classified from the underlying `NWError`
/// so the UI can give an accurate, actionable message instead of a generic one.
public enum CmxConnectFailureKind: Sendable, Equatable {
    /// The host is reachable but nothing is listening on the port: the Mac app
    /// is not running, or mobile pairing is turned off.
    case connectionRefused
    /// No route to the host: the Mac is off Tailscale, asleep, or offline.
    case hostUnreachable
    /// The connect attempt timed out (commonly the same as unreachable/asleep).
    case timedOut
    /// The OS blocked the connection (e.g. the iOS Local Network permission).
    case permissionDenied
    /// DNS resolution of the host failed.
    case dnsFailed
    /// The secure channel could not be established.
    case secureChannelFailed
    /// Anything else.
    case generic
}

/// Errors raised while establishing or operating a ``CmxNetworkByteTransport``.
public enum CmxNetworkByteTransportError: Error, Equatable, Sendable {
    /// The host was empty after trimming whitespace.
    case emptyHost
    /// The port fell outside `1...65535`.
    case invalidPort(Int)
    /// The configured maximum receive length was not positive.
    case invalidMaximumReceiveLength(Int)
    /// The route kind cannot be served by this network transport.
    case unsupportedRouteKind(CmxAttachTransportKind)
    /// The endpoint is not a host/port endpoint this transport can dial.
    case unsupportedEndpoint(CmxAttachEndpoint)
    /// A Tailscale route reached the route-only factory seam without an
    /// authorization context. Raw Tailscale TCP is never constructed there.
    case authorizationIntentRequired
    /// The request's authorization mode cannot be served by plaintext TCP.
    case unsupportedAuthorizationMode(CmxTransportAuthorizationMode)
    /// The exact legacy peer, live Tailscale-range tunnel, and effective
    /// connection endpoints could not all be proven.
    case tailscaleAuthorizationUnavailable
    /// An operation was attempted before the connection became ready.
    case notConnected
    /// The transport was already closed.
    case alreadyClosed
    /// A receive was requested while another is still in flight.
    case receiveAlreadyInProgress
    /// A send was requested while another is still in flight.
    case sendAlreadyInProgress
    /// The connect deadline elapsed before the connection became ready.
    case connectionTimedOut
    /// The connection failed; the associated values describe the cause and a
    /// classified ``CmxConnectFailureKind`` so the UI can give an actionable
    /// message.
    case connectionFailed(String, CmxConnectFailureKind)
    /// A receive failed; the associated value describes the cause.
    case receiveFailed(String)
    /// A send failed; the associated value describes the cause.
    case sendFailed(String)
}

/// A ``CmxByteTransport`` over a single Network.framework `NWConnection`.
///
/// The actor owns the connection, its callback queue, and all in-flight
/// continuations so connect/receive/send/close are serialized without locks.
public actor CmxNetworkByteTransport: CmxByteTransport {
    /// Default per-receive byte cap.
    public static let defaultMaximumReceiveLength = 64 * 1024
    /// Default connect deadline, after which ``connect()`` fails as timed out.
    public static let defaultConnectTimeoutNanoseconds: UInt64 = 15 * 1_000_000_000

    private enum TransportState {
        case idle
        case connecting
        case ready
        case failed(CmxNetworkByteTransportError)
        case closed
    }

    let connection: NWConnection
    // Network.framework requires a callback queue; state changes re-enter this actor.
    let callbackQueue: DispatchQueue
    let maximumReceiveLength: Int
    let connectTimeoutNanoseconds: UInt64
    let tailscaleBinding: CmxTailscaleTransportBinding?
    private var state: TransportState = .idle
    private var connectContinuations: [UUID: CheckedContinuation<Void, any Error>] = [:]
    private var receiveContinuation: (id: UUID, continuation: CheckedContinuation<Data?, any Error>)?
    private var receiveInFlightOperationID: UUID?
    private var receiveBuffer: [Data] = []
    private var sendContinuation: (id: UUID, continuation: CheckedContinuation<Void, any Error>?)?
    private var cancelledOperationIDs: Set<UUID> = []
    private var connectTimeoutTimer: (any DispatchSourceTimer)?
    private var remoteDidClose = false
    private var tailscalePathRevision: UInt64 = 0
    private var tailscaleAuthorizationInvalidated = false

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
        guard (1 ... 65535).contains(port) else {
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
        tailscaleBinding = nil
    }

    public init(
        route: CmxAttachRoute,
        maximumReceiveLength: Int = CmxNetworkByteTransport.defaultMaximumReceiveLength,
        connectTimeoutNanoseconds: UInt64 = CmxNetworkByteTransport.defaultConnectTimeoutNanoseconds
    ) throws {
        try route.validate()
        guard route.kind != .tailscale else {
            throw CmxNetworkByteTransportError.authorizationIntentRequired
        }
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

    public init(acceptedConnection: NWConnection) {
        connection = acceptedConnection
        callbackQueue = DispatchQueue(
            label: "dev.cmux.mobile.accepted-network-byte-transport.\(UUID().uuidString)"
        )
        maximumReceiveLength = Self.defaultMaximumReceiveLength
        connectTimeoutNanoseconds = Self.defaultConnectTimeoutNanoseconds
        tailscaleBinding = nil
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
            label: "dev.cmux.mobile.accepted-network-byte-transport.\(UUID().uuidString)"
        )
        self.maximumReceiveLength = maximumReceiveLength
        self.connectTimeoutNanoseconds = max(1, connectTimeoutNanoseconds)
        tailscaleBinding = nil
    }

    init(
        request: CmxByteTransportRequest,
        preparedTailscaleRoute: CmxPreparedTailscaleRoute,
        tailscaleRouteAuthority: any CmxTailscaleRouteAuthorizing,
        maximumReceiveLength: Int,
        connectTimeoutNanoseconds: UInt64 = CmxNetworkByteTransport.defaultConnectTimeoutNanoseconds
    ) throws {
        guard maximumReceiveLength > 0 else {
            throw CmxNetworkByteTransportError.invalidMaximumReceiveLength(maximumReceiveLength)
        }
        guard preparedTailscaleRoute.proof.request == request else {
            throw CmxNetworkByteTransportError.tailscaleAuthorizationUnavailable
        }
        guard let nwPort = NWEndpoint.Port(
            rawValue: UInt16(exactly: preparedTailscaleRoute.proof.peerPort) ?? 0
        ), nwPort != .any else {
            throw CmxNetworkByteTransportError.invalidPort(preparedTailscaleRoute.proof.peerPort)
        }

        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.noDelay = true
        let parameters = NWParameters(tls: nil, tcp: tcpOptions)
        parameters.requiredInterface = preparedTailscaleRoute.requiredInterface
        connection = NWConnection(
            host: preparedTailscaleRoute.proof.peerAddress.nwHost,
            port: nwPort,
            using: parameters
        )
        callbackQueue = DispatchQueue(
            label: "dev.cmux.mobile.tailscale-network-byte-transport.\(UUID().uuidString)"
        )
        self.maximumReceiveLength = maximumReceiveLength
        self.connectTimeoutNanoseconds = max(1, connectTimeoutNanoseconds)
        tailscaleBinding = CmxTailscaleTransportBinding(
            request: request,
            preparedRoute: preparedTailscaleRoute,
            authority: tailscaleRouteAuthority
        )
    }

    /// Opens the connection, awaiting `ready` or failing on error/timeout.
    /// - Throws: ``CmxNetworkByteTransportError`` or `CancellationError`.
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

    /// Receives the next chunk of bytes, or `nil` at end of stream.
    /// - Returns: The next received `Data`, or `nil` once the peer closed.
    /// - Throws: ``CmxNetworkByteTransportError`` or `CancellationError`.
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

    /// Sends bytes over the connection. Empty data is a no-op.
    /// - Parameter data: The bytes to write.
    /// - Throws: ``CmxNetworkByteTransportError`` or `CancellationError`.
    public func send(_ data: Data) async throws {
        guard !data.isEmpty else {
            return
        }
        try Task.checkCancellation()
        let operationID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                Task {
                    await self.startSend(
                        data,
                        operationID: operationID,
                        continuation: continuation
                    )
                }
            }
        } onCancel: {
            Task { await self.cancelSend(operationID: operationID) }
        }
    }

    /// Cancels the connection and completes any in-flight operations.
    ///
    /// A pending ``receive()`` resolves to `nil` (end of stream); pending
    /// connect/send calls fail with ``CmxNetworkByteTransportError/alreadyClosed``.
    public func close() async {
        close(
            pendingError: CmxNetworkByteTransportError.alreadyClosed,
            resumeReceiveWithError: false
        )
    }

    private func startConnect(
        operationID: UUID,
        continuation: CheckedContinuation<Void, any Error>
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
            if tailscaleBinding != nil {
                connection.pathUpdateHandler = { [weak self] path in
                    guard let self else { return }
                    Task { await self.handleTailscalePathUpdate(path) }
                }
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

    private func handleConnectionEvent(_ event: CmxNetworkConnectionEvent) async {
        switch event {
        case .ready:
            guard !isTerminal else {
                return
            }
            do {
                try await validateTailscaleAuthorizationForCurrentPath()
            } catch {
                failTransport(.tailscaleAuthorizationUnavailable)
                return
            }
            cancelConnectTimeout()
            state = .ready
            resumeConnectContinuations()
        case let .waiting(errorDescription, kind):
            // Network.framework parks a dial it intends to retry in `.waiting`
            // instead of `.failed` — including connection-refused and
            // host-unreachable, which for our single-address connect are
            // definitive answers, not transient congestion. Left alone, a
            // dead first route (stale Tailscale IP, a code pointing at a
            // machine with no listener) sits in `.waiting` until the connect
            // timeout and adds the whole timeout to scan→pair latency before
            // the caller's next route is tried. Fail the *initial* connect
            // fast on those definitive kinds; once `ready`, waiting events
            // are transient network churn and stay ignored (the RPC layer's
            // liveness watchdog owns mid-stream recovery).
            guard case .connecting = state, waitingKindFailsConnect(kind) else {
                break
            }
            failTransport(.connectionFailed(errorDescription, kind))
        case let .failed(errorDescription, kind):
            failTransport(.connectionFailed(errorDescription, kind))
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
        continuation: CheckedContinuation<Data?, any Error>
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
            let errorDescription = error.map(\.cmxUserFacingDescription)
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
        continuation: CheckedContinuation<Void, any Error>
    ) async {
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

        do {
            try await performAuthorizedWrite(
                authorization: {
                    try await validateTailscaleAuthorizationForCurrentPath()
                },
                beginWrite: {
                    beginSend(
                        data,
                        operationID: operationID,
                        continuation: continuation
                    )
                }
            )
        } catch {
            let transportError = CmxNetworkByteTransportError.tailscaleAuthorizationUnavailable
            continuation.resume(throwing: transportError)
            failTransport(transportError)
        }
    }

    private func beginSend(
        _ data: Data,
        operationID: UUID,
        continuation: CheckedContinuation<Void, any Error>
    ) {
        sendContinuation = (operationID, continuation)
        connection.send(
            content: data,
            contentContext: .defaultMessage,
            isComplete: false,
            completion: .contentProcessed { [weak self] error in
                let errorDescription = error.map(\.cmxUserFacingDescription)
                guard let self else { return }
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
            return
        }
        sendContinuation = nil

        if let errorDescription {
            let error = CmxNetworkByteTransportError.sendFailed(errorDescription)
            failTransport(error)
            pending.continuation?.resume(throwing: error)
            return
        }

        pending.continuation?.resume()
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
        connection.stateUpdateHandler = nil
        connection.pathUpdateHandler = nil
        connection.cancel()
        resumeConnectContinuations(throwing: error)
        resumeReceiveContinuation(throwing: error)
        resumeSendContinuation(throwing: error)
    }

    private func close(pendingError: any Error, resumeReceiveWithError: Bool) {
        guard !isClosed else {
            return
        }
        cancelConnectTimeout()
        state = .closed
        cancelledOperationIDs.removeAll()
        receiveBuffer.removeAll()
        receiveInFlightOperationID = nil
        connection.stateUpdateHandler = nil
        connection.pathUpdateHandler = nil
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
            cancelledOperationIDs.insert(operationID)
            pending.continuation?.resume(throwing: CancellationError())
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
        timer.schedule(
            deadline: .now() + DispatchTimeInterval.milliseconds(
                coveringNanoseconds: connectTimeoutNanoseconds
            )
        )
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

    private func handleTailscalePathUpdate(_ path: NWPath) async {
        guard tailscaleBinding != nil, !isTerminal else { return }
        tailscalePathRevision = tailscalePathRevision == .max ? 1 : tailscalePathRevision + 1
        do {
            try await validateTailscaleAuthorization(path: path)
        } catch {
            tailscaleAuthorizationInvalidated = true
            failTransport(.tailscaleAuthorizationUnavailable)
        }
    }

    private func validateTailscaleAuthorizationForCurrentPath() async throws {
        guard tailscaleBinding != nil else { return }
        guard let path = connection.currentPath else {
            throw CmxNetworkByteTransportError.tailscaleAuthorizationUnavailable
        }
        let revision = tailscalePathRevision
        try await validateTailscaleAuthorization(path: path)
        // The authority call yields this actor. Reject any connection-path
        // update that interleaved before the synchronous send boundary.
        guard revision == tailscalePathRevision else {
            throw CmxNetworkByteTransportError.tailscaleAuthorizationUnavailable
        }
    }

    private func validateTailscaleAuthorization(path: NWPath) async throws {
        guard let binding = tailscaleBinding else { return }
        guard !tailscaleAuthorizationInvalidated,
              binding.request == binding.preparedRoute.proof.request,
              connection.parameters.requiredInterface == binding.preparedRoute.requiredInterface else {
            throw CmxNetworkByteTransportError.tailscaleAuthorizationUnavailable
        }
        do {
            try await binding.authority.validate(
                proof: binding.preparedRoute.proof,
                connectionPath: path
            )
        } catch {
            throw CmxNetworkByteTransportError.tailscaleAuthorizationUnavailable
        }
    }

    /// The single legacy bearer-write boundary. Authorization completes before
    /// Network.framework receives the send request.
    func performAuthorizedWrite(
        authorization: () async throws -> Void,
        beginWrite: () -> Void
    ) async rethrows {
        try await authorization()
        beginWrite()
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

    private func resumeConnectContinuations(throwing error: (any Error)? = nil) {
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
        throwing error: (any Error)? = nil
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

    private func resumeSendContinuation(throwing error: any Error) {
        guard let pending = sendContinuation else {
            return
        }
        sendContinuation = nil
        pending.continuation?.resume(throwing: error)
    }
}
