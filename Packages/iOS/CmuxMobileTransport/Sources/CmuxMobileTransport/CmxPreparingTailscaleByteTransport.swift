internal import CMUXMobileCore
import Foundation

/// Defers the actor-isolated route proof until `connect()` while preserving the
/// synchronous transport-factory contract. The proven interface is set on
/// `NWParameters` before Network.framework starts the connection.
actor CmxPreparingTailscaleByteTransport: CmxByteTransport {
    private let request: CmxByteTransportRequest
    private let tailscaleRouteAuthority: any CmxTailscaleRouteAuthorizing
    private let maximumReceiveLength: Int
    private let connectTimeoutNanoseconds: UInt64
    private var preparationTask: Task<any CmxByteTransport, any Error>?
    private var transport: (any CmxByteTransport)?
    private var isClosed = false

    init(
        request: CmxByteTransportRequest,
        tailscaleRouteAuthority: any CmxTailscaleRouteAuthorizing,
        maximumReceiveLength: Int,
        connectTimeoutNanoseconds: UInt64
    ) {
        self.request = request
        self.tailscaleRouteAuthority = tailscaleRouteAuthority
        self.maximumReceiveLength = maximumReceiveLength
        self.connectTimeoutNanoseconds = connectTimeoutNanoseconds
    }

    func connect() async throws {
        let transport = try await preparedTransport()
        try await transport.connect()
    }

    func receive() async throws -> Data? {
        guard let transport else {
            throw isClosed
                ? CmxNetworkByteTransportError.alreadyClosed
                : CmxNetworkByteTransportError.notConnected
        }
        return try await transport.receive()
    }

    func send(_ data: Data) async throws {
        guard let transport else {
            throw isClosed
                ? CmxNetworkByteTransportError.alreadyClosed
                : CmxNetworkByteTransportError.notConnected
        }
        try await transport.send(data)
    }

    func close() async {
        guard !isClosed else { return }
        isClosed = true
        preparationTask?.cancel()
        if let transport {
            await transport.close()
        }
    }

    private func preparedTransport() async throws -> any CmxByteTransport {
        guard !isClosed else {
            throw CmxNetworkByteTransportError.alreadyClosed
        }
        if let transport {
            return transport
        }

        let task: Task<any CmxByteTransport, any Error>
        if let preparationTask {
            task = preparationTask
        } else {
            let request = request
            let authority = tailscaleRouteAuthority
            let maximumReceiveLength = maximumReceiveLength
            let connectTimeoutNanoseconds = connectTimeoutNanoseconds
            task = Task {
                do {
                    let prepared = try await authority.prepare(request: request)
                    try Task.checkCancellation()
                    return try CmxNetworkByteTransport(
                        request: request,
                        preparedTailscaleRoute: prepared,
                        tailscaleRouteAuthority: authority,
                        maximumReceiveLength: maximumReceiveLength,
                        connectTimeoutNanoseconds: connectTimeoutNanoseconds
                    )
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    throw CmxNetworkByteTransportError.tailscaleAuthorizationUnavailable
                }
            }
            preparationTask = task
        }

        do {
            let preparedTransport = try await task.value
            guard !isClosed else {
                await preparedTransport.close()
                throw CmxNetworkByteTransportError.alreadyClosed
            }
            transport = preparedTransport
            preparationTask = nil
            return preparedTransport
        } catch {
            preparationTask = nil
            throw error
        }
    }
}
