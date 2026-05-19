import Darwin
import Foundation

extension CMUXCLI {
    func withUseSocketClient<T>(
        socketPath: String,
        explicitPassword: String?,
        _ body: (SocketClient, Bool) throws -> T
    ) throws -> T {
        let client = SocketClient(path: socketPath)
        do {
            try client.connect()
        } catch {
            client.close()
            guard shouldLaunchAppAfterSocketConnectFailure(socketPath: socketPath) else {
                let connectError = String(describing: error)
                throw CLIError(message: String(
                    localized: "cli.use.error.socketConnectFailed",
                    defaultValue: "Failed to connect to cmux socket at \(socketPath): \(connectError)"
                ))
            }

            return try withLaunchedUseSocketClient(
                socketPath: socketPath,
                explicitPassword: explicitPassword,
                body
            )
        }

        defer { client.close() }
        try authenticateClientIfNeeded(
            client,
            explicitPassword: explicitPassword,
            socketPath: socketPath,
            allowV2Fallback: true
        )
        return try body(client, false)
    }

    private func withLaunchedUseSocketClient<T>(
        socketPath: String,
        explicitPassword: String?,
        _ body: (SocketClient, Bool) throws -> T
    ) throws -> T {
        try launchApp(strictOpenExit: true)
        let launchedClient = try SocketClient.waitForConnectableSocket(path: socketPath, timeout: 10)
        defer { launchedClient.close() }
        try authenticateClientIfNeeded(
            launchedClient,
            explicitPassword: explicitPassword,
            socketPath: socketPath,
            allowV2Fallback: true
        )
        return try body(launchedClient, true)
    }

    private func shouldLaunchAppAfterSocketConnectFailure(socketPath: String) -> Bool {
        guard socketPath.hasPrefix("/") else {
            return false
        }

        var metadata = stat()
        guard stat(socketPath, &metadata) == 0 else {
            return true
        }

        let fileType = metadata.st_mode & mode_t(S_IFMT)
        return fileType == mode_t(S_IFSOCK) && metadata.st_uid == getuid()
    }
}
