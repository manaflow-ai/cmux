import CmuxControlSocket
import Foundation

extension SocketClient {
    static func waitForConnectableSocket(path: String, timeout: TimeInterval) throws -> SocketClient {
        try waitForConnectableSocket(resolvePath: { path }, timeout: timeout)
    }

    /// Waits for a socket selected by `resolvePath` to become connectable.
    ///
    /// ``SocketStartupWaiter`` owns the shared deadline, path re-resolution,
    /// vnode wakeups, and backoff. This adapter owns CLI connection creation and
    /// classifies transport failures so permanent path conflicts surface
    /// immediately while startup races remain retryable.
    static func waitForConnectableSocket(
        resolvePath: () -> String,
        timeout: TimeInterval
    ) throws -> SocketClient {
        do {
            return try SocketStartupWaiter().wait(
                timeout: timeout,
                resolvePath: resolvePath
            ) { path, remainingTime in
                let client = SocketClient(path: path)
                do {
                    // Use the remaining total budget as the connect deadline so
                    // a full listen backlog cannot extend the bounded startup wait.
                    try client.connectWithoutRetry(
                        responseTimeout: max(remainingTime, 0.001)
                    )
                    if client.isRelayBacked {
                        client.close()
                    }
                    return client
                } catch {
                    client.close()
                    guard shouldRetrySocketStartup(error) else {
                        throw error
                    }
                    return nil
                }
            }
        } catch let startupTimeout as SocketStartupWaitTimeout {
            throw startupSocketTimeout(path: startupTimeout.path)
        }
    }

    static func isSocketStartupTimeout(_ error: Error) -> Bool {
        (error as? CLIError)?.socketFailureKind == .startupTimeout
    }

    private static func shouldRetrySocketStartup(_ error: Error) -> Bool {
        if shouldRetryConnect(error) {
            return true
        }
        return (error as? CLIError)?.socketFailureKind == .pathMissing
    }

    private static func startupSocketTimeout(path: String) -> CLIError {
        CLIError(
            message: "cmux app did not start in time (socket not found at \(path))",
            socketFailureKind: .startupTimeout
        )
    }
}
