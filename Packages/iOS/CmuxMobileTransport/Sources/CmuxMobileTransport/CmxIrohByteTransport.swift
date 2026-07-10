public import CMUXMobileCore
public import Foundation

/// A ``CmxRouteAwareByteTransportFactory`` that builds iroh byte transports for
/// peer routes.
public struct CmxIrohByteTransportFactory: CmxRouteAwareByteTransportFactory {
    /// The route kinds this factory can build a transport for.
    public var supportedKinds: [CmxAttachTransportKind] { [.iroh] }

    let endpointManager: CmxIrohEndpointManager
    let ffiClient: any CmxIrohFFIClient
    private let maximumReceiveLength: Int
    private let connectTimeoutNanoseconds: UInt64

    /// Creates a factory using a shared endpoint manager.
    public init(
        endpointManager: CmxIrohEndpointManager = CmxIrohEndpointManager(),
        maximumReceiveLength: Int = CmxIrohByteTransport.defaultMaximumReceiveLength,
        connectTimeoutNanoseconds: UInt64 = CmxIrohByteTransport.defaultConnectTimeoutNanoseconds
    ) {
        self.init(
            endpointManager: endpointManager,
            ffiClient: CmxIrohSystemFFIClient(),
            maximumReceiveLength: maximumReceiveLength,
            connectTimeoutNanoseconds: connectTimeoutNanoseconds
        )
    }

    init(
        endpointManager: CmxIrohEndpointManager,
        ffiClient: any CmxIrohFFIClient,
        maximumReceiveLength: Int = CmxIrohByteTransport.defaultMaximumReceiveLength,
        connectTimeoutNanoseconds: UInt64 = CmxIrohByteTransport.defaultConnectTimeoutNanoseconds
    ) {
        self.endpointManager = endpointManager
        self.ffiClient = ffiClient
        self.maximumReceiveLength = maximumReceiveLength
        self.connectTimeoutNanoseconds = connectTimeoutNanoseconds
    }

    /// Builds a connected-on-demand iroh transport for a supported peer route.
    public func makeTransport(for route: CmxAttachRoute) throws -> any CmxByteTransport {
        try CmxIrohByteTransport(
            route: route,
            endpointManager: endpointManager,
            ffiClient: ffiClient,
            maximumReceiveLength: maximumReceiveLength,
            connectTimeoutNanoseconds: connectTimeoutNanoseconds
        )
    }
}

/// A ``CmxByteTransport`` over one iroh bidirectional stream.
public actor CmxIrohByteTransport: CmxByteTransport {
    /// Default per-receive byte cap.
    public static let defaultMaximumReceiveLength = 64 * 1024
    /// Default iroh connect deadline.
    public static let defaultConnectTimeoutNanoseconds: UInt64 = 15 * 1_000_000_000

    private enum State {
        case idle
        case ready(CmxIrohConnectionReference)
        case closed
    }

    private let peerID: String
    private let relayURL: String?
    private let directAddrs: [String]
    private let endpointManager: CmxIrohEndpointManager
    private let ffiClient: any CmxIrohFFIClient
    private let maximumReceiveLength: Int
    private let connectTimeoutMilliseconds: UInt64
    private var state: State = .idle

    /// Creates an iroh transport from an attach route.
    public init(
        route: CmxAttachRoute,
        endpointManager: CmxIrohEndpointManager = CmxIrohEndpointManager(),
        maximumReceiveLength: Int = CmxIrohByteTransport.defaultMaximumReceiveLength,
        connectTimeoutNanoseconds: UInt64 = CmxIrohByteTransport.defaultConnectTimeoutNanoseconds
    ) throws {
        try self.init(
            route: route,
            endpointManager: endpointManager,
            ffiClient: CmxIrohSystemFFIClient(),
            maximumReceiveLength: maximumReceiveLength,
            connectTimeoutNanoseconds: connectTimeoutNanoseconds
        )
    }

    init(
        route: CmxAttachRoute,
        endpointManager: CmxIrohEndpointManager,
        ffiClient: any CmxIrohFFIClient,
        maximumReceiveLength: Int = CmxIrohByteTransport.defaultMaximumReceiveLength,
        connectTimeoutNanoseconds: UInt64 = CmxIrohByteTransport.defaultConnectTimeoutNanoseconds
    ) throws {
        try route.validate()
        guard route.kind == .iroh else {
            throw CmxIrohByteTransportError.unsupportedRouteKind(route.kind)
        }
        guard case let .peer(id, _, directAddrs, relayURL) = route.endpoint else {
            throw CmxIrohByteTransportError.unsupportedEndpoint(route.endpoint)
        }
        let normalizedPeerID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedPeerID.isEmpty else {
            throw CmxIrohByteTransportError.emptyPeerID
        }
        guard maximumReceiveLength > 0 else {
            throw CmxIrohByteTransportError.invalidMaximumReceiveLength(maximumReceiveLength)
        }
        self.peerID = normalizedPeerID
        self.relayURL = relayURL?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.directAddrs = directAddrs.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        self.endpointManager = endpointManager
        self.ffiClient = ffiClient
        self.maximumReceiveLength = maximumReceiveLength
        self.connectTimeoutMilliseconds = max(1, connectTimeoutNanoseconds / 1_000_000)
    }

    /// Opens the iroh stream.
    public func connect() async throws {
        try Task.checkCancellation()
        switch state {
        case .idle:
            break
        case .ready:
            return
        case .closed:
            throw CmxIrohByteTransportError.alreadyClosed
        }

        let endpoint = try await endpointManager.boundEndpoint()
        do {
            let connection = try ffiClient.connect(
                endpoint: endpoint,
                peerID: peerID,
                relayURL: relayURL,
                directAddrs: directAddrs,
                timeoutMilliseconds: connectTimeoutMilliseconds
            )
            state = .ready(connection)
        } catch let failure as CmxIrohFailure {
            throw CmxIrohByteTransportError.connectFailed(failure)
        }
    }

    /// Receives the next chunk of bytes, or `nil` at end of stream.
    public func receive() async throws -> Data? {
        try Task.checkCancellation()
        guard case let .ready(connection) = state else {
            if case .closed = state { return nil }
            throw CmxIrohByteTransportError.notConnected
        }
        do {
            return try ffiClient.receive(
                connection: connection,
                maximumLength: maximumReceiveLength
            )
        } catch let failure as CmxIrohFailure {
            throw CmxIrohByteTransportError.receiveFailed(failure)
        }
    }

    /// Sends bytes over the stream. Empty data is a no-op.
    public func send(_ data: Data) async throws {
        guard !data.isEmpty else {
            return
        }
        try Task.checkCancellation()
        guard case let .ready(connection) = state else {
            if case .closed = state {
                throw CmxIrohByteTransportError.alreadyClosed
            }
            throw CmxIrohByteTransportError.notConnected
        }
        do {
            try ffiClient.send(connection: connection, data: data)
        } catch let failure as CmxIrohFailure {
            throw CmxIrohByteTransportError.sendFailed(failure)
        }
    }

    /// Closes the stream and releases the FFI connection handle.
    public func close() async {
        guard case let .ready(connection) = state else {
            state = .closed
            return
        }
        state = .closed
        ffiClient.close(connection: connection)
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
