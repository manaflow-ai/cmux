import Network

/// The successful private-address dial and the hub stream carrying its bytes.
struct CloudHubConnection: Sendable {
    let connection: NWConnection
    let host: String
}
