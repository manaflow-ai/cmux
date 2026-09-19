import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxMobileTransport

@Test func webSocketTransportExchangesBinaryMessagesOverURLRoute() async throws {
    let server = try WebSocketEchoServer()
    let port = try await server.start()
    defer { server.stop() }

    let urlString = "ws://127.0.0.1:\(port)/echo"
    let route = try CmxAttachRoute(
        id: "websocket",
        kind: .websocket,
        endpoint: .url(urlString)
    )
    let transport = try CmxWebSocketByteTransportFactory().makeTransport(for: route)
    let payload = Data("websocket-ping".utf8)

    do {
        try await transport.connect()
        try await transport.send(payload)
        let response = try await transport.receive()
        let diagnostics = await transport.connectionDiagnostics()
        await transport.close()

        #expect(response == payload)
        #expect(diagnostics.kind == .websocket)
        #expect(diagnostics.endpoint == .url(urlString))
        #expect(diagnostics.rttMilliseconds == nil)
    } catch {
        await transport.close()
        throw error
    }
}

@Test func webSocketTransportFactoryRejectsNonWebSocketRouteKind() throws {
    let route = try CmxAttachRoute(
        id: "loopback",
        kind: .debugLoopback,
        endpoint: .hostPort(host: "127.0.0.1", port: 1234)
    )

    #expect(throws: CmxWebSocketByteTransportError.unsupportedRouteKind(.debugLoopback)) {
        _ = try CmxWebSocketByteTransportFactory().makeTransport(for: route)
    }
}

@Test func webSocketTransportFactoryRejectsNonURLEndpoint() throws {
    let factory = CmxWebSocketByteTransportFactory(supportedKinds: [.debugLoopback])
    let route = try CmxAttachRoute(
        id: "loopback",
        kind: .debugLoopback,
        endpoint: .hostPort(host: "127.0.0.1", port: 1234)
    )

    #expect(
        throws: CmxWebSocketByteTransportError.unsupportedEndpoint(
            .hostPort(host: "127.0.0.1", port: 1234)
        )
    ) {
        _ = try factory.makeTransport(for: route)
    }
}
