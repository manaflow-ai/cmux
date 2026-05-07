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

    func launchApp(strictOpenExit: Bool = false) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", "cmux"]

        let stderrURL: URL?
        let stderrHandle: FileHandle?
        if strictOpenExit {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("cmux-open-stderr-\(UUID().uuidString).log", isDirectory: false)
            _ = FileManager.default.createFile(atPath: url.path, contents: nil, attributes: nil)
            let handle: FileHandle
            do {
                handle = try FileHandle(forWritingTo: url)
            } catch {
                try? FileManager.default.removeItem(at: url)
                throw error
            }
            process.standardError = handle
            stderrURL = url
            stderrHandle = handle
        } else {
            stderrURL = nil
            stderrHandle = nil
        }
        defer {
            try? stderrHandle?.close()
            if let stderrURL {
                try? FileManager.default.removeItem(at: stderrURL)
            }
        }

        try process.run()
        process.waitUntilExit()
        try? stderrHandle?.close()
        guard strictOpenExit, process.terminationStatus != 0 else {
            return
        }
        let stderrData = stderrURL.flatMap { try? Data(contentsOf: $0) } ?? Data()
        let stderr = String(data: stderrData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let detail = stderr.isEmpty ? "" : ": \(stderr)"
        throw CLIError(message: "open -a cmux failed with exit \(process.terminationStatus)\(detail)")
    }
}
