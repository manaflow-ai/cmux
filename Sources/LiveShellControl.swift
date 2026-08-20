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

/// Outcome of mapping an observed livesh session id onto the daemon's authoritative id.
///
/// livesh abbreviates the session id in its own process title (`livesh (sh_<8 hex>) <cwd>`), so an
/// id scraped from that title is a display value, never a durable key. Handing an abbreviated id
/// back to `livesh --open` does not reattach: livesh silently creates a NEW daemon session, which
/// is how a restored pane loses its shell and orphans the original one across a cmux restart.
/// Observed ids are therefore resolved against the daemon before being persisted as a resume
/// checkpoint.
enum LiveShellSessionIDResolution: Equatable, Sendable {
    /// Exactly one daemon session id starts with the observed value.
    case resolved(String)
    /// The daemon could not be consulted, so callers keep the observed id unchanged.
    case unavailable
    /// The daemon reported no session for the observed id.
    case notFound
    /// Several daemon sessions share the observed prefix, so no id can be chosen safely.
    case ambiguous
}

/// Consults the livesh daemon at most once, then answers every id from that one snapshot.
///
/// Process-detection scans run on a timer and walk many panes per pass, so the listing is fetched
/// lazily — only once a livesh bridge is actually detected — and reused for the rest of the pass.
final class LiveShellSessionIDCache {
    private var sessionIDs: [String]?
    private var didFetch = false

    func resolve(_ observedSessionID: String) -> LiveShellSessionIDResolution {
        if !didFetch {
            didFetch = true
            sessionIDs = LiveShellControl.listSessionIDsSynchronously()
        }
        return LiveShellControl.resolveSessionID(observedSessionID, in: sessionIDs)
    }
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

    /// Synchronously reads the daemon's full session ids, or `nil` when no usable listing came back.
    ///
    /// Process-detection scanning is synchronous, so this blocks instead of hopping through the
    /// async `list()`. stderr is discarded and stdout is drained before `waitUntilExit()`, so a
    /// listing larger than the pipe buffer cannot deadlock.
    static func listSessionIDsSynchronously() -> [String]? {
        guard let executable = LiveShellSettings.resolvedLiveshctlExecutable() else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["list", "--json"]
        let stdoutPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            logger.error("livesh id listing failed to launch: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, !stdoutData.isEmpty else { return nil }
        do {
            let decoded = try JSONDecoder()
                .decode([LiveShellSessionInfo].self, from: stdoutData)
                .map(\.id)
            return authoritativeSessionIDs(decoded)
        } catch {
            logger.error("decode livesh id listing failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Treats only a non-empty listing as authoritative.
    ///
    /// An empty listing cannot distinguish "the daemon owns no shells" from "liveshctl answered with
    /// nothing useful". Accepting it would resolve every observed id to `.notFound` and drop EVERY
    /// livesh binding from the persisted snapshot, losing restore for panes whose shells are alive —
    /// strictly worse than carrying a possibly stale id. Only a non-empty listing may justify
    /// `.notFound`.
    static func authoritativeSessionIDs(_ decoded: [String]) -> [String]? {
        decoded.isEmpty ? nil : decoded
    }

    /// Maps an observed session id onto the daemon's authoritative full id.
    ///
    /// An exact hit wins outright; otherwise the observed value is treated as the prefix livesh
    /// renders in its process title and must select exactly one daemon session.
    static func resolveSessionID(
        _ observedSessionID: String,
        in sessionIDs: [String]?
    ) -> LiveShellSessionIDResolution {
        guard let sessionIDs else { return .unavailable }
        if sessionIDs.contains(observedSessionID) { return .resolved(observedSessionID) }
        let matches = sessionIDs.filter { $0.hasPrefix(observedSessionID) }
        guard let match = matches.first else { return .notFound }
        guard matches.count == 1 else { return .ambiguous }
        return .resolved(match)
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
