public import Foundation
import Darwin
import os

/// Diagnostics for partial pipe reads; mirrors the app-side ProcessPipeReader
/// warning the lifted code emitted (file-scoped `os.Logger` per house style).
nonisolated private let logger = Logger(subsystem: "com.cmuxterm.app", category: "MultiWindowRouter")

/// Runs the bundled cmux CLI against the app's control socket to route a
/// request to a specific window, capturing its output.
///
/// This is the production ``MultiWindowRouting``, extracted from AppDelegate's
/// `runMultiWindowRouteCLI`: it spawns the CLI with an implicit
/// `--socket <path>` argument pair and an explicit child environment (the
/// child inherits nothing beyond what is injected), then captures termination
/// status and both streams. A launch failure throws
/// ``MultiWindowRouteLaunchError``; a launched CLI always returns a result.
///
/// Isolation design: the router holds only immutable `Sendable` configuration
/// (CLI URL, socket path, environment), so there is no state to protect and an
/// actor would serialize unrelated route calls for no benefit (the same ruling
/// that made `CmuxProcess.CommandRunner` a stateless struct). The legacy
/// synchronous `waitUntilExit` is replaced by a `terminationHandler`
/// continuation, so `route` never blocks its calling thread; the two stream
/// readers run on detached tasks (the `CommandRunner` pattern) so a stream
/// larger than the pipe buffer cannot deadlock the child against an unread
/// pipe.
public struct MultiWindowRouter: MultiWindowRouting, Sendable {
    private let cliURL: URL
    private let socketPath: String
    // Environment is value-like once copied; stored immutable so the struct
    // stays Sendable.
    private let environment: [String: String]

    /// Creates a router for one CLI binary, socket, and child environment.
    /// - Parameters:
    ///   - cliURL: The bundled cmux CLI executable.
    ///   - socketPath: The control socket path passed to every call as
    ///     `--socket <path>`.
    ///   - environment: The complete child process environment (replaces, not
    ///     merges with, the app's environment).
    public init(cliURL: URL, socketPath: String, environment: [String: String]) {
        self.cliURL = cliURL
        self.socketPath = socketPath
        self.environment = environment
    }

    /// Runs the CLI with `arguments` and captures its outcome.
    ///
    /// Implements ``MultiWindowRouting/route(arguments:)``; see the protocol
    /// for the full contract and the type docs for the isolation rationale.
    public func route(arguments: [String]) async throws -> MultiWindowRouteResult {
        let process = Process()
        process.executableURL = cliURL
        process.arguments = ["--socket", socketPath] + arguments
        process.environment = environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // Drain both streams on detached tasks, keyed by raw fd so no
        // non-Sendable FileHandle crosses the task boundary. Started before the
        // spawn so a child that fills a pipe buffer can never deadlock against
        // an unread pipe; the reads block until data or EOF arrives.
        let stdoutDescriptor = stdoutPipe.fileHandleForReading.fileDescriptor
        let stderrDescriptor = stderrPipe.fileHandleForReading.fileDescriptor
        let stdoutReader = Task.detached {
            self.readDataToEndOfFileOrEmpty(fromFileDescriptor: stdoutDescriptor)
        }
        let stderrReader = Task.detached {
            self.readDataToEndOfFileOrEmpty(fromFileDescriptor: stderrDescriptor)
        }

        let terminationStatus: Int32
        do {
            terminationStatus = try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { finished in
                    continuation.resume(returning: finished.terminationStatus)
                }
                do {
                    try process.run()
                    // Close the parent's write ends so the readers see EOF once
                    // the child closes its copies.
                    try? stdoutPipe.fileHandleForWriting.close()
                    try? stderrPipe.fileHandleForWriting.close()
                } catch {
                    process.terminationHandler = nil
                    try? stdoutPipe.fileHandleForWriting.close()
                    try? stderrPipe.fileHandleForWriting.close()
                    continuation.resume(
                        throwing: MultiWindowRouteLaunchError(description: String(describing: error))
                    )
                }
            }
        } catch {
            // The write ends are closed, so the readers finish on EOF; await
            // them before rethrowing so no detached work outlives the call.
            _ = await stdoutReader.value
            _ = await stderrReader.value
            throw error
        }

        let stdoutData = await stdoutReader.value
        let stderrData = await stderrReader.value
        return MultiWindowRouteResult(
            terminationStatus: terminationStatus,
            stdout: String(data: stdoutData, encoding: .utf8) ?? "",
            stderr: String(data: stderrData, encoding: .utf8) ?? ""
        )
    }

    /// Reads `fileDescriptor` to end-of-file, retrying `EINTR`, returning
    /// partial data (with a logged warning) on a read error. Carried over from
    /// the app-side `ProcessPipeReader.readDataToEndOfFileOrEmpty`, which stays
    /// app-target for its other callers. Operates on the raw descriptor so the
    /// detached reader tasks capture only `Sendable` values (`self` is a
    /// Sendable value type).
    private func readDataToEndOfFileOrEmpty(fromFileDescriptor fileDescriptor: Int32) -> Data {
        let chunkSize = 64 * 1024
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: chunkSize)
        while true {
            let bytesRead = buffer.withUnsafeMutableBytes { pointer -> Int in
                guard let baseAddress = pointer.baseAddress else { return 0 }
                return Darwin.read(fileDescriptor, baseAddress, chunkSize)
            }
            if bytesRead > 0 {
                data.append(contentsOf: buffer[0..<bytesRead])
                continue
            }
            if bytesRead == 0 {
                return data
            }
            let code = errno
            if code == EINTR {
                continue
            }
            logger.warning(
                "multiWindowRouter.readFailed errno=\(Int(code), privacy: .public) fd=\(fileDescriptor, privacy: .public) partialBytes=\(data.count, privacy: .public)"
            )
            return data
        }
    }
}
