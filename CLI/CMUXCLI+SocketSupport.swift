import Foundation

extension CMUXCLI {
    func authenticateClientIfNeeded(
        _ client: SocketClient,
        explicitPassword: String?,
        socketPath: String,
        allowV2Fallback: Bool = false
    ) throws {
        if let socketPassword = SocketPasswordResolver.resolve(
            explicit: explicitPassword,
            socketPath: socketPath
        ) {
            let authResponse = try client.send(command: "auth \(socketPassword)")
            if authResponse.hasPrefix("ERROR:"),
               authResponse.contains("Unknown command 'auth'") {
                guard allowV2Fallback else {
                    return
                }
                let v2Response = try client.sendV2(method: "auth.login", params: ["password": socketPassword])
                guard v2Response["authenticated"] as? Bool == true else {
                    throw CLIError(message: "auth.login failed")
                }
            } else if authResponse.hasPrefix("ERROR:") {
                throw CLIError(message: authResponse)
            }
        }
    }

    func launchApp() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", "cmux"]
        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        try process.run()
        process.waitUntilExit()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        let stderr = String(data: stderrData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard process.terminationStatus == 0 else {
            let detail = stderr.isEmpty ? "" : ": \(stderr)"
            throw CLIError(message: "open -a cmux failed with exit \(process.terminationStatus)\(detail)")
        }
    }
}
