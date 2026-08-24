import Foundation

struct LocalTmuxProcessResult: Sendable {
    let status: Int32
    let stdout: String
    let stderr: String

    var succeeded: Bool { status == 0 }
}

/// Runs short-lived tmux control commands without inheriting cmux socket secrets.
struct LocalTmuxProcessRunner {
    let executablePath: String
    let environment: [String: String]

    init(
        executablePath: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.executablePath = executablePath
        var sanitized = environment
        sanitized.removeValue(forKey: "TMUX")
        sanitized.removeValue(forKey: "CMUX_SOCKET_PASSWORD")
        sanitized.removeValue(forKey: "CMUX_SOCKET")
        sanitized.removeValue(forKey: "CMUX_SOCKET_PATH")
        sanitized.removeValue(forKey: "CMUX_SOCKET_PASSWORD_FILE")
        // A detached owner must not retain a stale workspace/surface identity
        // or a socket credential from the GUI that launched it.
        sanitized = sanitized.filter { !$0.key.hasPrefix("CMUX_") && !$0.key.hasPrefix("CMUXD_") }
        self.environment = sanitized
    }

    func run(arguments: [String]) throws -> LocalTmuxProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw CLIError(message: "local-tmux could not run tmux: \(error)", exitCode: 127)
        }

        let stdout = String(decoding: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let stderr = String(decoding: stderrPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return LocalTmuxProcessResult(
            status: process.terminationStatus,
            stdout: stdout,
            stderr: stderr
        )
    }

    func requireSuccess(_ arguments: [String], context: String) throws -> LocalTmuxProcessResult {
        let result = try run(arguments: arguments)
        guard result.succeeded else {
            let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw CLIError(message: detail.isEmpty ? "local-tmux \(context) failed (exit \(result.status))" : "local-tmux \(context) failed: \(detail)")
        }
        return result
    }
}
