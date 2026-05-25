import Foundation
import OSLog

struct LiveShellSessionInfo: Codable, Equatable, Hashable, Sendable, Identifiable {
    let id: String
    let name: String
    let status: LiveShellStatus
    let cwd: String
    let shellPath: String
    let createdAtMs: UInt64
    let lastActiveAtMs: UInt64
    let attached: Bool

    private enum CodingKeys: String, CodingKey {
        case id, name, status, cwd
        case shellPath = "shell_path"
        case createdAtMs = "created_at_ms"
        case lastActiveAtMs = "last_active_at_ms"
        case attached
    }
}

enum LiveShellStatus: String, Codable, Equatable, Hashable, Sendable {
    case running = "Running"
    case exited = "Exited"
    case lost = "Lost"
}

/// Thin async wrapper around the `liveshctl` CLI. All calls are off-main and tolerate
/// the daemon being unavailable.
enum LiveShellControl {
    private static let logger = Logger(subsystem: "ai.manaflow.cmux", category: "LiveShellControl")

    enum LiveShellControlError: Error, LocalizedError {
        case executableNotFound
        case daemonUnavailable
        case nonZeroExit(code: Int32, stderr: String)
        case decodeFailure(underlying: Error)

        var errorDescription: String? {
            switch self {
            case .executableNotFound:
                return "liveshctl binary not found"
            case .daemonUnavailable:
                return "liveshd daemon not available"
            case .nonZeroExit(let code, let stderr):
                return "liveshctl exited with code \(code): \(stderr)"
            case .decodeFailure(let underlying):
                return "Failed to decode liveshctl output: \(underlying.localizedDescription)"
            }
        }
    }

    /// liveshctl uses exit code 69 (EX_UNAVAILABLE) when the daemon socket can't be reached.
    private static let exitCodeDaemonUnavailable: Int32 = 69

    static func list() async throws -> [LiveShellSessionInfo] {
        let result = try await runProcess(arguments: ["list", "--json"])
        switch result {
        case .success(let stdout):
            let trimmed = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return [] }
            guard let data = trimmed.data(using: .utf8) else { return [] }
            do {
                return try JSONDecoder().decode([LiveShellSessionInfo].self, from: data)
            } catch {
                logger.error("decode list output failed: \(error.localizedDescription, privacy: .public)")
                throw LiveShellControlError.decodeFailure(underlying: error)
            }
        case .daemonUnavailable:
            throw LiveShellControlError.daemonUnavailable
        case .nonZero(let code, let stderr):
            throw LiveShellControlError.nonZeroExit(code: code, stderr: stderr)
        }
    }

    static func kill(sessionId: String) async throws {
        let trimmed = sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let result = try await runProcess(arguments: ["kill", trimmed])
        switch result {
        case .success:
            return
        case .daemonUnavailable:
            throw LiveShellControlError.daemonUnavailable
        case .nonZero(let code, let stderr):
            throw LiveShellControlError.nonZeroExit(code: code, stderr: stderr)
        }
    }

    static func gc() async throws {
        let result = try await runProcess(arguments: ["gc"])
        switch result {
        case .success:
            return
        case .daemonUnavailable:
            throw LiveShellControlError.daemonUnavailable
        case .nonZero(let code, let stderr):
            throw LiveShellControlError.nonZeroExit(code: code, stderr: stderr)
        }
    }

    private enum ProcessResult {
        case success(stdout: String)
        case daemonUnavailable
        case nonZero(code: Int32, stderr: String)
    }

    private static func runProcess(arguments: [String]) async throws -> ProcessResult {
        guard let executable = LiveShellSettings.resolvedLiveshctlExecutable() else {
            throw LiveShellControlError.executableNotFound
        }
        return try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe
            process.standardInput = FileHandle.nullDevice
            try process.run()
            // Drain both pipes concurrently so a child producing more than the pipe buffer
            // (~64 KB on macOS) can't deadlock waiting for us to read.
            async let stdoutFuture = Self.readAll(handle: stdoutPipe.fileHandleForReading)
            async let stderrFuture = Self.readAll(handle: stderrPipe.fileHandleForReading)
            let stdoutData = await stdoutFuture
            let stderrData = await stderrFuture
            process.waitUntilExit()
            let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
            let stderr = String(data: stderrData, encoding: .utf8) ?? ""
            let code = process.terminationStatus
            if code == 0 {
                return ProcessResult.success(stdout: stdout)
            }
            if code == LiveShellControl.exitCodeDaemonUnavailable {
                return ProcessResult.daemonUnavailable
            }
            return ProcessResult.nonZero(code: code, stderr: stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }.value
    }

    private static func readAll(handle: FileHandle) async -> Data {
        await Task.detached(priority: .userInitiated) {
            handle.readDataToEndOfFile()
        }.value
    }
}

/// Static exit codes published by livesh / liveshctl. Mirrors §1.1 of cmux-livesh.md.
enum LiveShellExitCode {
    /// Shell no longer exists in the daemon (e.g. daemon crashed or shell exited externally).
    static let shellLost: Int32 = 66
    /// Daemon socket unreachable.
    static let daemonUnavailable: Int32 = 69
}
