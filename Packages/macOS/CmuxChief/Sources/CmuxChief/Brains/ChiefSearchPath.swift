import Darwin
import Foundation

/// The `PATH` a Chief turn's shell commands search.
///
/// An app opened from the Dock or Finder inherits launchd's minimal `PATH`
/// (`/usr/bin:/bin:/usr/sbin:/sbin`), so tools the user runs in Terminal,
/// such as `gh` from Homebrew, would be "command not found" for the brain.
/// The login shell's `PATH` comes first, as in the user's terminal, then the
/// app's, then the usual install places.
public enum ChiefSearchPath {
    /// Install places searched when neither `PATH` names them.
    ///
    /// - Parameter home: The user's home directory.
    /// - Returns: The directories, most specific first.
    static func fallbackDirectories(home: String) -> [String] {
        ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "\(home)/.npm-global/bin"]
    }

    /// Merges the login shell's `PATH` into the app's.
    ///
    /// - Parameters:
    ///   - base: The app's `PATH`.
    ///   - loginShell: The login shell's `PATH`, nil when it could not be read.
    ///   - home: The user's home directory.
    /// - Returns: A `PATH` with each directory once.
    public static func merged(base: String, loginShell: String?, home: String) -> String {
        var seen = Set<String>()
        var directories: [String] = []
        let candidates = (loginShell ?? "").split(separator: ":").map(String.init)
            + base.split(separator: ":").map(String.init)
            + fallbackDirectories(home: home)
        for directory in candidates where !directory.isEmpty && seen.insert(directory).inserted {
            directories.append(directory)
        }
        return directories.joined(separator: ":")
    }
}

/// The user's login-shell `PATH`, read once per app and shared by every turn.
public actor ChiefLoginShellPath {
    /// The lookup for this app.
    public static let shared = ChiefLoginShellPath {
        await run(shell: ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh", timeout: .seconds(5))
    }

    /// Precedes the `PATH` in the shell's output, so profile output is skipped.
    static let marker = "__CMUX_CHIEF_PATH__="

    private let lookup: @Sendable () async -> String?
    private var task: Task<String?, Never>?

    /// Creates a lookup.
    ///
    /// - Parameter lookup: Reads the login shell's `PATH`; it runs at most once.
    public init(lookup: @escaping @Sendable () async -> String?) {
        self.lookup = lookup
    }

    /// The login shell's `PATH`, nil when it could not be read.
    public func value() async -> String? {
        if let task { return await task.value }
        let task = Task { await lookup() }
        self.task = task
        return await task.value
    }

    /// The `PATH` after the marker, nil without one or when it is empty.
    static func parse(_ output: String) -> String? {
        guard let range = output.range(of: marker, options: .backwards) else { return nil }
        let path = output[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }

    /// Runs `shell -lc` to print its `PATH`, killing it at `timeout`.
    static func run(shell: String, timeout: Duration) async -> String? {
        await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: shell)
            process.arguments = ["-lc", "printf '%s%s' '\(marker)' \"$PATH\""]
            process.standardInput = FileHandle.nullDevice
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
            } catch {
                return nil
            }
            let processID = process.processIdentifier
            let deadline = Task.detached(priority: .utility) {
                do {
                    try await ContinuousClock().sleep(for: timeout)
                } catch {
                    return false
                }
                _ = Darwin.kill(processID, SIGKILL)
                return true
            }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            deadline.cancel()
            guard await !deadline.value, process.terminationStatus == 0,
                  let text = String(data: data, encoding: .utf8) else { return nil }
            return parse(text)
        }.value
    }
}
