import Network

/// The successful private-address dial and the hub stream carrying its bytes.
public struct CloudHubConnection: Sendable {
    public let connection: NWConnection
    public let host: String

    public init(
        connection: NWConnection,
        host: String
    ) {
        self.connection = connection
        self.host = host
    }
}
