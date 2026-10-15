import Darwin
import Foundation

/// One agent CLI child process that speaks JSON Lines over stdio.
///
/// stdout is read by the pipe's readability handler (no polling) and framed
/// into ``lines``, in order, which ends when the process closes stdout.
/// stderr keeps a short tail for error messages. Writes never raise
/// `SIGPIPE`: a write to a dead process fails quietly and the reader sees
/// the end of ``lines``.
final class ChiefLineProcess: @unchecked Sendable {
    /// stdout, one element per line, finished at end of stream.
    let lines: AsyncStream<Data>
    /// The child's pid, for logs.
    var pid: Int32 { process.processIdentifier }

    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let errors = Pipe()
    private let lock = NSLock()
    private let writeLock = NSLock()
    private var framer = ChiefLineFramer()
    private var stderrTail = Data()
    private var closed = false
    private static let stderrLimit = 4096

    /// Launches the process.
    ///
    /// - Parameters:
    ///   - executable: The program to run.
    ///   - arguments: Its arguments.
    ///   - environment: Its complete environment.
    ///   - workingDirectory: Its working directory.
    /// - Throws: When the program cannot be launched.
    init(executable: URL, arguments: [String], environment: [String: String], workingDirectory: URL) throws {
        let (stream, continuation) = AsyncStream.makeStream(of: Data.self, bufferingPolicy: .unbounded)
        lines = stream
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = workingDirectory
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)

        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self else {
                handle.readabilityHandler = nil
                continuation.finish()
                return
            }
            if data.isEmpty {
                handle.readabilityHandler = nil
                if let tail = self.withLock({ self.framer.finish() }) { continuation.yield(tail) }
                continuation.finish()
                return
            }
            for line in self.withLock({ self.framer.append(data) }) { continuation.yield(line) }
        }
        errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self, !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            self.withLock {
                self.stderrTail.append(data)
                if self.stderrTail.count > Self.stderrLimit {
                    self.stderrTail = self.stderrTail.suffix(Self.stderrLimit)
                }
            }
        }
        do {
            try process.run()
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
            errors.fileHandleForReading.readabilityHandler = nil
            continuation.finish()
            throw error
        }
    }

    /// Writes one line to stdin.
    ///
    /// - Parameter line: Bytes ending in a newline.
    /// - Returns: False when stdin is closed or the process is gone.
    @discardableResult
    func write(_ line: Data) -> Bool {
        // A separate lock: a blocked write must not stall the stdout reader.
        writeLock.lock()
        defer { writeLock.unlock() }
        guard !withLock({ closed }) else { return false }
        do {
            try input.fileHandleForWriting.write(contentsOf: line)
            return true
        } catch {
            return false
        }
    }

    /// The last few KB the process wrote to stderr, trimmed.
    var stderrText: String {
        let tail = withLock { stderrTail }
        return String(decoding: tail, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether the process still runs.
    var isRunning: Bool { process.isRunning }

    /// Closes stdin and terminates the process. Safe to call more than once.
    func terminate() {
        let wasOpen: Bool = withLock {
            defer { closed = true }
            return !closed
        }
        guard wasOpen else { return }
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

/// Finds an agent CLI and builds its environment.
///
/// The CLI is looked up on the `PATH` of the turn's environment (the app's
/// own `PATH` otherwise), so the user's install wins, unless an explicit
/// override path is configured.
enum ChiefExecutableResolver {
    /// The process environment for a CLI: the app's environment, then the
    /// turn's, then `overrides`.
    ///
    /// - Parameters:
    ///   - request: The turn's extra environment.
    ///   - overrides: Values that always win (hook opt-outs).
    /// - Returns: The complete environment.
    static func environment(_ request: [String: String], overrides: [String: String]) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        // The app is not a terminal; a Chief must not claim one.
        for key in ["CMUX_SURFACE_ID", "CMUX_PANEL_ID", "CMUX_WORKSPACE_ID", "CMUX_TAB_ID"] {
            environment.removeValue(forKey: key)
        }
        environment.merge(request) { _, new in new }
        environment.merge(overrides) { _, new in new }
        return environment
    }

    /// Resolves `name` to an executable file.
    ///
    /// - Parameters:
    ///   - name: The program name, such as `claude`.
    ///   - override: An explicit path that wins when it is executable.
    ///   - environment: The environment whose `PATH` is searched.
    /// - Returns: The executable, nil when none is found.
    static func resolve(_ name: String, override: URL?, environment: [String: String]) -> URL? {
        let files = FileManager.default
        if let override, files.isExecutableFile(atPath: override.path) { return override }
        let path = environment["PATH"] ?? ProcessInfo.processInfo.environment["PATH"] ?? ""
        var directories = path.split(separator: ":").map(String.init)
        // A GUI app's PATH is minimal; also try the usual install places.
        let home = files.homeDirectoryForCurrentUser.path
        directories += ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "\(home)/.npm-global/bin"]
        for directory in directories where !directory.isEmpty {
            let candidate = URL(fileURLWithPath: directory, isDirectory: true).appendingPathComponent(name)
            if files.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }
}
