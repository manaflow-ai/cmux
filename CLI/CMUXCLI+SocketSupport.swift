import Foundation

extension CMUXCLI {
    func authenticateClientIfNeeded(
        _ client: SocketClient,
        explicitPassword: String?,
        socketPath: String
    ) throws {
        if let socketPassword = SocketPasswordResolver.resolve(
            explicit: explicitPassword,
            socketPath: socketPath
        ) {
            let authResponse = try client.send(command: "auth \(socketPassword)")
            if authResponse.hasPrefix("ERROR:"),
               !authResponse.contains("Unknown command 'auth'") {
                throw CLIError(message: authResponse)
            }
        }
    }

    func launchApp() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", "cmux"]
        try process.run()
        process.waitUntilExit()
    }
}
