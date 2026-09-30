import Foundation

/// Opens an initialized ``AcpmuxSessionAPI``, starting the daemon when needed.
public protocol AcpmuxConnecting: Sendable {
    /// Connects and sends `initialize`.
    func connect() async throws -> any AcpmuxSessionAPI
}

/// Connects to the daemon described by an ``AcpmuxDaemonEnvironment``.
public struct AcpmuxDaemonConnector: AcpmuxConnecting {
    /// The daemon location.
    public let environment: AcpmuxDaemonEnvironment
    private let launcher: AcpmuxDaemonLauncher
    private let clientName: String
    private let clientVersion: String

    /// Creates a connector.
    /// - Parameters:
    ///   - environment: Where the daemon lives.
    ///   - launcher: Starts the daemon when the socket does not answer.
    ///   - clientName: Sent in `initialize`; acpmux shows it as the event `client`.
    ///   - clientVersion: Sent in `initialize`.
    public init(environment: AcpmuxDaemonEnvironment, launcher: AcpmuxDaemonLauncher, clientName: String, clientVersion: String) {
        self.environment = environment
        self.launcher = launcher
        self.clientName = clientName
        self.clientVersion = clientVersion
    }

    public func connect() async throws -> any AcpmuxSessionAPI {
        let path = environment.socketPath
        let client: JSONRPCClient
        if let existing = try? JSONRPCClient(socketPath: path) {
            client = existing
        } else {
            let box = try await launcher.launch(environment) {
                (try? JSONRPCClient(socketPath: path)).map(ClientBox.init)
            }
            client = box.client
        }
        let api = AcpmuxRPCSessionAPI(client: client)
        try await api.initialize(clientName: clientName, version: clientVersion)
        return api
    }

    private struct ClientBox: Sendable {
        let client: JSONRPCClient
    }
}
