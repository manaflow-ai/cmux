import CmuxNextDaemon
import Foundation

extension CloudPlaceFlows {
    /// Files with uncommitted changes (tracked and untracked) in `folder`, from `git status --porcelain=v1 -z`,
    /// read off the main actor and bound to 2 s. Nil when there is no folder, it is not a checkout, or git fails or is slow.
    /// The home folder's own repository (a dotfiles `~/.git`; `homePath`, else the person's) counts its tracked
    /// changes only: its untracked files are the whole home folder, and listing them reads the Photos library and
    /// Desktop in cmux's name (LAUNCH-NO-TCC-PROMPTS; cmux-git `home.rs`).
    public nonisolated static func dirtyFiles(in folder: String?, homePath: String? = nil) async -> Int? {
        guard let folder, !folder.isEmpty else { return nil }
        let homePath = homePath ?? NSHomeDirectory()
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        let git = URL(fileURLWithPath: "/usr/bin/git")
        guard let top = try? await ProcessRunner.run(
            executable: git, arguments: ["-C", folder, "rev-parse", "--show-toplevel"],
            environment: environment, timeout: .seconds(2), clock: ContinuousClock()), top.status == 0 else { return nil }
        let resolved = { (path: String) in URL(fileURLWithPath: path, isDirectory: true).resolvingSymlinksInPath().path }
        let topPath = String(decoding: top.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let untracked = resolved(topPath) == resolved(homePath) ? "--untracked-files=no" : "--untracked-files=normal"
        guard let result = try? await ProcessRunner.run(
            executable: git,
            arguments: ["-C", folder, "status", "--porcelain=v1", "-z", untracked],
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
