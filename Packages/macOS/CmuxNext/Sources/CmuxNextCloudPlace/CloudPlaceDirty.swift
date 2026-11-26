import CmuxNextDaemon
import Foundation

extension CloudPlaceFlows {
    /// Files with uncommitted changes (tracked and untracked) in `folder`, from `git status --porcelain=v1 -z`,
    /// read off the main actor and bound to 2 s. Nil when there is no folder, it is not a checkout, or git fails or is slow.
    public nonisolated static func dirtyFiles(in folder: String?) async -> Int? {
        guard let folder, !folder.isEmpty else { return nil }
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        guard let result = try? await ProcessRunner.run(
            executable: URL(fileURLWithPath: "/usr/bin/git"),
            arguments: ["-C", folder, "status", "--porcelain=v1", "-z", "--untracked-files=normal"],
            environment: environment, timeout: .seconds(2), clock: ContinuousClock()), result.status == 0 else { return nil }
        return dirtyCount(porcelainZ: result.stdout)
    }

    /// Entries in `status --porcelain=v1 -z`: `XY path`, with a rename or copy followed by its source path, which is no file of its own.
    nonisolated static func dirtyCount(porcelainZ output: Data) -> Int {
        var count = 0, skipNext = false
        for field in output.split(separator: 0, omittingEmptySubsequences: true) {
            if skipNext { skipNext = false; continue }
            guard field.count >= 3 else { continue }
            count += 1
            let status = field.prefix(2)
            skipNext = status.contains(UInt8(ascii: "R")) || status.contains(UInt8(ascii: "C"))
        }
        return count
    }
}
