import CmuxHomeCore
import Darwin
import Foundation

/// The `PATH` a Chief turn's shell commands search.
///
/// An app opened from the Dock or Finder inherits launchd's minimal `PATH`
/// (`/usr/bin:/bin:/usr/sbin:/sbin`), so tools the user runs in Terminal,
/// such as `gh` from Homebrew, would be "command not found" for the brain.
/// The login shell's `PATH` comes first, as in the user's terminal, then the
/// app's, then the usual install places.
public struct ChiefSearchPath: Sendable, Equatable {
    /// The user's home directory.
    public let home: String

    /// Creates the search path for a user.
    ///
    /// - Parameter home: The user's home directory.
    public init(home: String) {
        self.home = home
    }

    /// Install places searched when neither `PATH` names them, most specific first.
    var fallbackDirectories: [String] {
        ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "\(home)/.npm-global/bin"]
    }

    /// Merges the login shell's `PATH` into the app's.
    ///
    /// - Parameters:
    ///   - base: The app's `PATH`.
    ///   - loginShell: The login shell's `PATH`, nil when it could not be read.
    /// - Returns: A `PATH` with each absolute directory once; relative or
    ///   unexpanded entries (`.`, `$PATH`) are dropped.
    public func merged(base: String, loginShell: String?) -> String {
        var seen = Set<String>()
        var directories: [String] = []
        let candidates = (loginShell ?? "").split(separator: ":").map(String.init)
            + base.split(separator: ":").map(String.init)
            + fallbackDirectories
        for directory in candidates where directory.hasPrefix("/") && seen.insert(directory).inserted {
            directories.append(directory)
        }
        return directories.joined(separator: ":")
    }
}

/// The user's login-shell `PATH`, read once per app and shared by every turn.
///
/// A failed read is retried once (a slow profile right after login can miss
/// the deadline), then the turns keep the app's `PATH`.
public actor ChiefLoginShellPath {
    /// The lookup for this app.
    public static let shared = ChiefLoginShellPath {
        await run(shell: userShell, timeout: .seconds(5))
    }

    /// Precedes the `PATH` in the shell's output, so profile output is skipped.
    static let marker = "__CMUX_CHIEF_PATH__="
    /// Follows the `PATH`, so the read ends without waiting for the pipe to close.
    static let endMarker = "__CMUX_CHIEF_PATH_END__"
    /// How many times a lookup that found nothing runs.
    static let attempts = 2

    private let lookup: @Sendable () async -> String?
    private var task: Task<String?, Never>?
    private var failures = 0

    /// Creates a lookup.
    ///
    /// - Parameter lookup: Reads the login shell's `PATH`, nil on failure.
    public init(lookup: @escaping @Sendable () async -> String?) {
        self.lookup = lookup
    }

    /// The login shell's `PATH`, nil when it could not be read.
    public func value() async -> String? {
        if let task { return await task.value }
        guard failures < Self.attempts else { return nil }
        let task = Task { await lookup() }
        self.task = task
        let path = await task.value
        if path == nil {
            failures += 1
            self.task = nil
        }
        return path
    }

    /// The user's shell: `SHELL`, else the account's, else zsh.
    static var userShell: String {
        if let shell = ProcessInfo.processInfo.environment["SHELL"], !shell.isEmpty { return shell }
        if let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell { return String(cString: shell) }
        return "/bin/zsh"
    }

    /// Whether `shell` accepts `-lc` and expands `"$PATH"` (csh, tcsh and
    /// nushell do not).
    static func supports(_ shell: String) -> Bool {
        !["csh", "tcsh", "nu"].contains(URL(fileURLWithPath: shell).lastPathComponent)
    }

    /// The `PATH` between the markers, nil without both or when it is empty.
    static func parse(_ output: String) -> String? {
        guard let start = output.range(of: marker, options: .backwards),
              let end = output.range(of: endMarker, range: start.upperBound..<output.endIndex) else { return nil }
        let path = output[start.upperBound..<end.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }

    /// Runs `shell -lc` to print its `PATH`.
    ///
    /// The read ends at the end marker, when the shell fails or at `timeout`,
    /// never by waiting for the pipe to close: a background job the profile
    /// starts can hold the shell's stdout for as long as it runs.
    static func run(shell: String, timeout: Duration) async -> String? {
        guard supports(shell) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-lc", "printf '%s%s%s' '\(marker)' \"$PATH\" '\(endMarker)'"]
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let output = Pipe()
        process.standardOutput = output
        return await withCheckedContinuation { continuation in
            let read = ChiefLoginShellRead(process: process, reader: output.fileHandleForReading,
                                           continuation: continuation)
            output.fileHandleForReading.readabilityHandler = { handle in
                read.append(handle.availableData)
            }
            process.terminationHandler = { process in
                read.exited(status: process.terminationStatus)
            }
            do {
                try process.run()
            } catch {
                read.finish(nil)
                return
            }
            // task-owner: the lookup's deadline; cancelled when the read finishes first
            read.start(deadline: Task {
                guard (try? await HomeSleepClock().sleep(for: timeout)) != nil else { return }
                read.finish(nil)
            })
        }
    }
}

/// One login-shell read: collects output and resumes its caller exactly once.
private final class ChiefLoginShellRead: @unchecked Sendable {
    private let lock = NSLock()
    private let reader: FileHandle
    private var process: Process?
    private var output = Data()
    private var deadline: Task<Void, Never>?
    private var continuation: CheckedContinuation<String?, Never>?

    init(process: Process, reader: FileHandle, continuation: CheckedContinuation<String?, Never>) {
        self.process = process
        self.reader = reader
        self.continuation = continuation
    }

    /// Adds output; an empty chunk is the end of the pipe.
    func append(_ data: Data) {
        lock.lock()
        output.append(data)
        let text = String(decoding: output, as: UTF8.self)
        lock.unlock()
        if let path = ChiefLoginShellPath.parse(text) {
            finish(path)
        } else if data.isEmpty {
            finish(nil)
        }
    }

    /// The shell exited; a failure ends the read, a success waits for the end marker.
    func exited(status: Int32) {
        lock.lock()
        process = nil
        lock.unlock()
        if status != 0 { finish(nil) }
    }

    func start(deadline: Task<Void, Never>) {
        lock.lock()
        let finished = continuation == nil
        if !finished { self.deadline = deadline }
        lock.unlock()
        if finished { deadline.cancel() }
    }

    /// Resumes the caller once, stops reading and kills a shell still running
    /// (one the profile hung; its background jobs are left alone).
    func finish(_ path: String?) {
        lock.lock()
        guard let continuation else {
            lock.unlock()
            return
        }
        self.continuation = nil
        let running = process
        let deadline = self.deadline
        lock.unlock()
        // No close here: a handler call in flight on another queue would read a
        // closed handle. The read end closes when the handle is released.
        reader.readabilityHandler = nil
        deadline?.cancel()
        if let running, running.isRunning { kill(running.processIdentifier, SIGKILL) }
        continuation.resume(returning: path)
    }
}
