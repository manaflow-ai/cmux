@preconcurrency import Foundation

/// A connected page target returned by the bounded Chromium startup race.
struct ChromiumBrowserStartupConnection: Sendable {
    let connection: ChromiumCDPConnection
    let endpoint: BrowserCDPEndpoint?
}

/// Bounds only the child/CDP handshake, leaving a first-run runtime download
/// free to complete at network speed before the deadline begins.
struct ChromiumBrowserStartupCoordinator: Sendable {
    private let endpointDiscovery: ChromiumCDPEndpointDiscovery
    private let loopbackSession: URLSession
    private let startupDeadline: @Sendable () async throws -> Void

    init(
        loopbackSession: URLSession,
        startupDeadline: @escaping @Sendable () async throws -> Void
    ) {
        self.endpointDiscovery = ChromiumCDPEndpointDiscovery(session: loopbackSession)
        self.loopbackSession = loopbackSession
        self.startupDeadline = startupDeadline
    }

    func establishConnection(
        transport: ChromiumDebuggingTransport,
        pipeTransport: ChromiumCDPPipeTransport?,
        diagnostics: ChromiumProcessDiagnostics
    ) async throws -> ChromiumBrowserStartupConnection {
        try await withThrowingTaskGroup(of: ChromiumBrowserStartupConnection.self) { group in
            group.addTask {
                try await connect(
                    transport: transport,
                    pipeTransport: pipeTransport,
                    diagnostics: diagnostics
                )
            }
            group.addTask {
                try await startupDeadline()
                try Task.checkCancellation()
                throw ChromiumBrowserDiagnostic.startupTimedOut
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else {
                throw CancellationError()
            }
            return first
        }
    }

    private func connect(
        transport: ChromiumDebuggingTransport,
        pipeTransport: ChromiumCDPPipeTransport?,
        diagnostics: ChromiumProcessDiagnostics
    ) async throws -> ChromiumBrowserStartupConnection {
        var establishedConnection: ChromiumCDPConnection?
        do {
            let connection: ChromiumCDPConnection
            let endpoint: BrowserCDPEndpoint?
            switch transport {
            case .pipe:
                guard let pipeTransport else { throw CDPError.notConnected }
                connection = ChromiumCDPConnection(transport: pipeTransport)
                endpoint = nil
            case .loopback(let port):
                try await diagnostics.waitForReadiness(expectedPort: port)
                let websocketURL = try await endpointDiscovery.pageWebSocketURL(port: port)
                connection = try ChromiumCDPConnection(
                    endpoint: websocketURL,
                    session: loopbackSession
                )
                endpoint = BrowserCDPEndpoint(port: port, websocketURL: websocketURL)
            }
            establishedConnection = connection
            try await connection.connect()
            if case .pipe = transport {
                try await connection.attachToPageTarget()
            }
            try Task.checkCancellation()
            return ChromiumBrowserStartupConnection(
                connection: connection,
                endpoint: endpoint
            )
        } catch {
            establishedConnection?.close()
            throw error
        }
    }
}
