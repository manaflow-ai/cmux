import Foundation

/// `Process.run()`, on the caller's thread.
struct ProcessLauncher: ProcessLaunching {
    nonisolated func launch(_ executable: URL, arguments: [String], environment: [String: String]) -> Bool {
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
