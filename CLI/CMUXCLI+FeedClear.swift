import Foundation
import CMUXAgentLaunch

// Clear history through the journal owner, with a product-safe error boundary.
extension CMUXCLI {
    func runFeedClear() async throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let path = home
            .appendingPathComponent(".cmuxterm", isDirectory: true)
            .appendingPathComponent("workstream.jsonl", isDirectory: false)
        let fm = FileManager.default
        guard fm.fileExists(atPath: path.path) else {
            print("No Feed history to clear (\(path.path) does not exist).")
            return
        }
        let skipConfirm = ProcessInfo.processInfo.arguments.contains("--yes")
            || ProcessInfo.processInfo.arguments.contains("-y")
        if !skipConfirm {
            print("This will permanently delete \(path.path). Proceed? [y/N] ", terminator: "")
            guard readLine()?.lowercased().hasPrefix("y") == true else {
                print("Aborted.")
                return
            }
        }
        // Route through the actor so clearing preserves the durable revision
        // floor before removing the JSONL file. Direct deletion would let a
        // byte-count-derived generation fall back to a stale sidecar.
        do {
            try await WorkstreamPersistence(fileURL: path).clear()
        } catch {
            throw CLIError(message: String(
                localized: "cli.feed.clear.error",
                defaultValue: "Could not clear Feed history. Check cmux permissions and try again."
            ))
        }
        print("Cleared \(path.path)")
    }

}
