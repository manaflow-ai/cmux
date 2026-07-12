import Darwin
import Foundation

/// Builds a bounded Git working-tree patch for transport to a mobile client.
final class MobileWorkingTreeDiffLoader: Sendable {
    private let maximumPatchBytes = 6 * 1024 * 1024
    private let maximumUntrackedFiles = 200
    private let maximumPathListBytes = 1024 * 1024
    private let maximumErrorBytes = 64 * 1024

    func load(directory: String, title: String) async throws -> [String: Any] {
        let repoResult = try await runGit(
            ["rev-parse", "--show-toplevel"],
            directory: directory,
            maximumStdoutBytes: 64 * 1024
        )
        guard repoResult.status == 0,
              let repositoryRoot = String(data: repoResult.stdout, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !repositoryRoot.isEmpty else {
            throw MobileWorkingTreeDiffLoadError(code: "not_found", message: "Workspace is not inside a Git repository")
        }

        let hasHead = (try await runGit(
            ["rev-parse", "--verify", "HEAD"],
            directory: repositoryRoot,
            maximumStdoutBytes: 1024
        )).status == 0
        var patch = Data()
        let trackedArgumentSets = hasHead
            ? [["diff", "--no-ext-diff", "--no-textconv", "--binary", "HEAD", "--"]]
            : [
                ["diff", "--cached", "--no-ext-diff", "--no-textconv", "--binary", "--"],
                ["diff", "--no-ext-diff", "--no-textconv", "--binary", "--"],
            ]
        for arguments in trackedArgumentSets {
            let tracked = try await runGit(
                arguments,
                directory: repositoryRoot,
                maximumStdoutBytes: maximumPatchBytes - patch.count
            )
            guard tracked.status == 0 else {
                throw MobileWorkingTreeDiffLoadError(code: "git_error", message: "Git diff failed")
            }
            guard !tracked.stdoutOverflowed else {
                throw MobileWorkingTreeDiffLoadError(code: "too_large", message: "Workspace diff is too large to send to this phone")
            }
            patch.append(tracked.stdout)
        }

        let untracked = try await runGit(
            ["ls-files", "--others", "--exclude-standard", "-z"],
            directory: repositoryRoot,
            maximumStdoutBytes: maximumPathListBytes
        )
        guard untracked.status == 0 else {
            throw MobileWorkingTreeDiffLoadError(code: "git_error", message: "Could not list untracked files")
        }
        let paths = untracked.stdout.split(separator: 0)
        guard !untracked.stdoutOverflowed, paths.count <= maximumUntrackedFiles else {
            throw MobileWorkingTreeDiffLoadError(code: "too_many_files", message: "Workspace has too many untracked files to display")
        }
        for pathData in paths {
            guard let path = String(data: Data(pathData), encoding: .utf8), !path.isEmpty else { continue }
            let result = try await runGit(
                ["diff", "--no-index", "--no-textconv", "--binary", "--", "/dev/null", path],
                directory: repositoryRoot,
                maximumStdoutBytes: maximumPatchBytes - patch.count
            )
            guard result.status == 0 || result.status == 1 else {
                throw MobileWorkingTreeDiffLoadError(code: "git_error", message: "Could not diff untracked file")
            }
            guard !result.stdoutOverflowed else {
                throw MobileWorkingTreeDiffLoadError(code: "too_large", message: "Workspace diff is too large to send to this phone")
            }
            patch.append(result.stdout)
        }

        guard let patchText = String(data: patch, encoding: .utf8) else {
            throw MobileWorkingTreeDiffLoadError(code: "invalid_data", message: "Workspace diff is not valid UTF-8")
        }
        return ["patch": patchText, "repository_root": repositoryRoot, "title": title]
    }

    private func runGit(
        _ arguments: [String],
        directory: String,
        maximumStdoutBytes: Int
    ) async throws -> (status: Int32, stdout: Data, stdoutOverflowed: Bool) {
        try Task.checkCancellation()
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", directory] + arguments
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice

        let stdoutFD = stdout.fileHandleForReading.fileDescriptor
        let stderrFD = stderr.fileHandleForReading.fileDescriptor
        let stdoutRead = Task.detached {
            Self.drain(fileDescriptor: stdoutFD, maximumBytes: max(0, maximumStdoutBytes))
        }
        let stderrRead = Task.detached { [maximumErrorBytes] in
            Self.drain(fileDescriptor: stderrFD, maximumBytes: maximumErrorBytes)
        }
        let cancellation = MobileDiffProcessCancellation(process: process)

        let status: Int32
        do {
            status = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    process.terminationHandler = { process in
                        continuation.resume(returning: process.terminationStatus)
                    }
                    do {
                        try process.run()
                    } catch {
                        process.terminationHandler = nil
                        continuation.resume(throwing: error)
                    }
                }
            } onCancel: {
                cancellation.cancel()
            }
            try Task.checkCancellation()
        } catch {
            cancellation.cancel()
            stdout.fileHandleForReading.closeFile()
            stderr.fileHandleForReading.closeFile()
            _ = await stdoutRead.value
            _ = await stderrRead.value
            if error is CancellationError { throw error }
            throw MobileWorkingTreeDiffLoadError(code: "git_error", message: "Could not start Git")
        }
        let output = await stdoutRead.value
        _ = await stderrRead.value
        return (status, output.data, output.overflowed)
    }

    /// Drains a pipe to EOF while retaining only the caller's bounded prefix.
    private static func drain(
        fileDescriptor: Int32,
        maximumBytes: Int
    ) -> (data: Data, overflowed: Bool) {
        var data = Data()
        var overflowed = false
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let bufferCapacity = buffer.count
            let count = buffer.withUnsafeMutableBytes { pointer in
                read(fileDescriptor, pointer.baseAddress, bufferCapacity)
            }
            if count > 0 {
                let retainedCount = min(count, max(0, maximumBytes - data.count))
                if retainedCount > 0 { data.append(contentsOf: buffer[0..<retainedCount]) }
                overflowed = overflowed || count > retainedCount
            } else if count == 0 {
                break
            } else if errno != EINTR {
                break
            }
        }
        return (data, overflowed)
    }
}
