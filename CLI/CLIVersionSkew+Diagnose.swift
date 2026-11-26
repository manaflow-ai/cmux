import Foundation

extension CLIVersionSkew {
    /// Rewrites an uncaught `method_not_found` into a version-skew error, or
    /// returns `error` unchanged when it is not one.
    static func diagnose(
        _ error: Error,
        client: SocketClient,
        cliVersion: String,
        cliShortVersion: String?,
        cliBuild: String?,
        cliPath: String?
    ) -> Error {
        guard let failure = error as? CLIError,
              failure.isStructuredProtocolResponse,
              failure.v2Code == "method_not_found",
              let method = failure.v2Method,
              method != "system.identify" else {
            return error
        }
        let peer: Peer?
        do {
            peer = Peer(identify: try client.sendV2(method: "system.identify", responseTimeout: 2))
        } catch {
            peer = nil
        }
        guard let message = message(
            method: method,
            socketPath: client.socketPath,
            cliVersion: cliVersion,
            cliShortVersion: cliShortVersion,
            cliBuild: cliBuild,
            cliPath: cliPath,
            peer: peer,
            original: failure.message
        ) else {
            return error
        }
        return CLIError(
            message: message,
            exitCode: failure.exitCode,
            v2Code: failure.v2Code,
            isStructuredProtocolResponse: true,
            v2Method: method
        )
    }
}
