internal import Darwin

struct PersistentSocketConnectDependencies: Sendable {
    let makeSocket: @Sendable () -> Int32
    let connect: @Sendable (Int32, String) -> Int32

    static let live = PersistentSocketConnectDependencies(
        makeSocket: { Darwin.socket(AF_UNIX, SOCK_STREAM, 0) },
        connect: { socket, path in
            SocketTransport().connectUnixSocket(socket, to: path)
        }
    )
}
