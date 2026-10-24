public import Foundation

/// ``ProcessLaunching`` with `Process.run()`, on the caller's thread (the sender's actor).
public nonisolated struct ProcessLauncher: ProcessLaunching {
    /// A launcher.
    public init() {}

    /// Starts `executable` with `Process`.
    public nonisolated func launch(_ executable: URL, arguments: [String], environment: [String: String]) -> Bool {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        do {
            try process.run()
            return true
        } catch {
            return false
        }
    }
}
