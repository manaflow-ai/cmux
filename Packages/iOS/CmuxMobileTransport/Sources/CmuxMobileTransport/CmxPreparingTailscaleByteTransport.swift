internal import CMUXMobileCore
import Foundation

/// Compatibility wrapper for callers compiled against the pre-stable API.
///
/// It no longer performs a provider-specific preparation step. The route is
/// normalized once and handed to the same actor-owned TCP transport as every
/// other connection. Keeping this tiny adapter source-compatible lets older
/// persisted pairing records migrate without reviving the Tailscale state
/// machine.
@available(*, deprecated, message: "Use CmxNetworkByteTransportFactory")
actor CmxPreparingTailscaleByteTransport: CmxByteTransport {
    private let route: CmxAttachRoute
    private let maximumReceiveLength: Int
    private let connectTimeoutNanoseconds: UInt64
    private var transport: CmxNetworkByteTransport?
    private var closed = false

    init(
        request: CmxByteTransportRequest,
        tailscaleRouteAuthority _: any CmxTailscaleRouteAuthorizing,
        maximumReceiveLength: Int,
        connectTimeoutNanoseconds: UInt64
    ) {
        route = request.route
        self.maximumReceiveLength = maximumReceiveLength
        self.connectTimeoutNanoseconds = connectTimeoutNanoseconds
    }

    func connect() async throws {
        try await getTransport().connect()
    }

    func receive() async throws -> Data? {
        try await getTransport().receive()
    }

    func send(_ data: Data) async throws {
        try await getTransport().send(data)
    }

    func close() async {
        guard !closed else { return }
        closed = true
        await transport?.close()
    }

    private func getTransport() throws -> CmxNetworkByteTransport {
        guard !closed else { throw CmxNetworkByteTransportError.alreadyClosed }
        if let transport { return transport }
        let created = try CmxNetworkByteTransport(
            route: route,
            maximumReceiveLength: maximumReceiveLength,
            connectTimeoutNanoseconds: connectTimeoutNanoseconds
        )
        transport = created
        return created
    }
}
