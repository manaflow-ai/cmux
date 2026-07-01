import Foundation

enum CmuxGitDiffAvailability {
    static func hasDisplayableDiff(in directory: String) -> Bool {
        let trimmed = directory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: trimmed, isDirectory: &isDirectory),
              isDirectory.boolValue else { return false }
        guard runGit(["-C", trimmed, "rev-parse", "--is-inside-work-tree"]) == 0 else {
            return false
        }

        // `git diff --quiet` exits 1 when a diff exists and 0 when it is empty.
        if runGit(["-C", trimmed, "diff", "--quiet", "--ignore-submodules=dirty", "--"]) == 1 {
            return true
        }
        if runGit(["-C", trimmed, "diff", "--cached", "--quiet", "--ignore-submodules=dirty", "--"]) == 1 {
            return true
        }
        return false
    }

    private static func runGit(_ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            return -1
        }
    }
}
