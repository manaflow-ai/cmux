import Darwin
import Foundation
import CMUXMobileCore

/// Builds a bounded Git working-tree patch for transport to a mobile client.
final class MobileWorkingTreeDiffLoader: Sendable {
    private let maximumPatchBytes = 6 * 1024 * 1024
    private let maximumChangedFiles = 200
    private let maximumPathListBytes = 1024 * 1024
    private let maximumErrorBytes = 64 * 1024
    private let responseEnvelopeBudget = 64 * 1024
    private let loadTimeout = Duration.seconds(15)
    private let clock = ContinuousClock()
    private let environment: [String: String]

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.environment = environment
    }

    func load(directory: String, title: String) async throws -> [String: Any] {
        try await loadPayload(directory: directory, title: title).rpcValue
    }

    func loadPayload(directory: String, title: String) async throws -> MobileWorkingTreeDiffPayload {
        let result = try await withThrowingTaskGroup(
            of: (patch: String, repositoryRoot: String, title: String).self
        ) { group in
            group.addTask {
                try await self.loadResult(directory: directory, title: title)
            }
            group.addTask {
                try await self.clock.sleep(for: self.loadTimeout)
                throw MobileWorkingTreeDiffLoadError(code: "timed_out", message: "Workspace diff took too long to load")
            }
            guard let result = try await group.next() else {
                throw MobileWorkingTreeDiffLoadError(code: "git_error", message: "Could not load workspace diff")
            }
            group.cancelAll()
            return result
        }
        let payload = MobileWorkingTreeDiffPayload(
            patch: result.patch,
            repositoryRoot: result.repositoryRoot,
            title: result.title
        )
        let document = payload.rpcValue
        let maximumDocumentBytes = MobileSyncFrameCodec.defaultMaximumFrameByteCount - responseEnvelopeBudget
        guard let encodedDocument = try? JSONSerialization.data(withJSONObject: document),
              encodedDocument.count <= maximumDocumentBytes else {
            throw MobileWorkingTreeDiffLoadError(code: "too_large", message: "Workspace diff is too large to send to this phone")
        }
        return payload
    }

    private func loadResult(
        directory: String,
        title: String
    ) async throws -> (patch: String, repositoryRoot: String, title: String) {
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
        var individualPaths: [Data] = []
        var trackedFileCount = 0
        if hasHead {
            let trackedPaths = try await runGit(
                ["diff", "--name-only", "-z", "--no-ext-diff", "--no-textconv", "HEAD", "--"],
                directory: repositoryRoot,
                maximumStdoutBytes: maximumPathListBytes
            )
            guard !trackedPaths.stdoutOverflowed else {
                throw MobileWorkingTreeDiffLoadError(code: "too_many_files", message: "Workspace has too many files to display")
            }
            guard trackedPaths.status == 0 else {
                throw MobileWorkingTreeDiffLoadError(code: "git_error", message: "Could not list changed files")
            }
            trackedFileCount = trackedPaths.stdout.split(separator: UInt8(0)).count
            guard trackedFileCount <= maximumChangedFiles else {
                throw MobileWorkingTreeDiffLoadError(code: "too_many_files", message: "Workspace has too many files to display")
            }
            let tracked = try await runGit(
                ["diff", "--no-ext-diff", "--no-textconv", "--binary", "HEAD", "--"],
                directory: repositoryRoot,
                maximumStdoutBytes: maximumPatchBytes
            )
            guard !tracked.stdoutOverflowed else {
                throw MobileWorkingTreeDiffLoadError(code: "too_large", message: "Workspace diff is too large to send to this phone")
            }
            guard tracked.status == 0 else {
                throw MobileWorkingTreeDiffLoadError(code: "git_error", message: "Git diff failed")
            }
            patch.append(tracked.stdout)
        } else {
            let indexed = try await runGit(
                ["ls-files", "-z"],
                directory: repositoryRoot,
                maximumStdoutBytes: maximumPathListBytes
            )
            guard !indexed.stdoutOverflowed else {
                throw MobileWorkingTreeDiffLoadError(code: "too_many_files", message: "Workspace has too many files to display")
            }
            guard indexed.status == 0 else {
                throw MobileWorkingTreeDiffLoadError(code: "git_error", message: "Could not list indexed files")
            }
            individualPaths = indexed.stdout.split(separator: UInt8(0)).map { Data($0) }
        }

        let untracked = try await runGit(
            ["ls-files", "--others", "--exclude-standard", "-z"],
            directory: repositoryRoot,
            maximumStdoutBytes: maximumPathListBytes
        )
        let untrackedPaths = untracked.stdout.split(separator: UInt8(0)).map { Data($0) }
        guard !untracked.stdoutOverflowed,
              trackedFileCount + individualPaths.count + untrackedPaths.count <= maximumChangedFiles else {
            throw MobileWorkingTreeDiffLoadError(code: "too_many_files", message: "Workspace has too many files to display")
        }
        guard untracked.status == 0 else {
            throw MobileWorkingTreeDiffLoadError(code: "git_error", message: "Could not list untracked files")
        }
        individualPaths.append(contentsOf: untrackedPaths)
        for pathData in individualPaths {
            guard let path = String(data: pathData, encoding: .utf8) else {
                throw MobileWorkingTreeDiffLoadError(code: "invalid_data", message: "Workspace contains a file path that is not valid UTF-8")
            }
            guard !path.isEmpty else { continue }
            guard let fileKind = Self.diffableFileKind(path, repositoryRoot: repositoryRoot) else { continue }
            if fileKind == .symbolicLink {
                let symlinkPatch = try Self.symlinkPatch(path: path, repositoryRoot: repositoryRoot)
                guard patch.count + symlinkPatch.count <= maximumPatchBytes else {
                    throw MobileWorkingTreeDiffLoadError(code: "too_large", message: "Workspace diff is too large to send to this phone")
                }
                patch.append(symlinkPatch)
                continue
            }
            let result = try await runGit(
                ["diff", "--no-index", "--no-ext-diff", "--no-textconv", "--binary", "--", "/dev/null", path],
                directory: repositoryRoot,
                maximumStdoutBytes: maximumPatchBytes - patch.count
            )
            guard !result.stdoutOverflowed else {
                throw MobileWorkingTreeDiffLoadError(code: "too_large", message: "Workspace diff is too large to send to this phone")
            }
            guard result.status == 0 || result.status == 1 else {
                throw MobileWorkingTreeDiffLoadError(code: "git_error", message: "Could not diff untracked file")
            }
            patch.append(result.stdout)
        }

        guard let patchText = String(data: patch, encoding: .utf8) else {
            throw MobileWorkingTreeDiffLoadError(code: "invalid_data", message: "Workspace diff is not valid UTF-8")
        }
        return (patchText, repositoryRoot, title)
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
        process.environment = sanitizedGitEnvironment()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice

        let cancellation = MobileDiffProcessCancellation(process: process)
        let stdoutFD = stdout.fileHandleForReading.fileDescriptor
        let stderrFD = stderr.fileHandleForReading.fileDescriptor
        let stdoutRead = Task.detached {
            Self.drain(
                fileDescriptor: stdoutFD,
                maximumBytes: max(0, maximumStdoutBytes),
                cancellationOnOverflow: cancellation
            )
        }
        let stderrRead = Task.detached { [maximumErrorBytes] in
            Self.drain(fileDescriptor: stderrFD, maximumBytes: maximumErrorBytes)
        }

        let status: Int32
        do {
            status = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    process.terminationHandler = { process in
                        cancellation.didExit()
                        continuation.resume(returning: process.terminationStatus)
                    }
                    do {
                        guard cancellation.beginLaunch() else {
                            process.terminationHandler = nil
                            continuation.resume(throwing: CancellationError())
                            return
                        }
                        try process.run()
                        cancellation.didLaunch()
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

    private func sanitizedGitEnvironment() -> [String: String] {
        var sanitized = environment.filter { key, _ in !key.hasPrefix("GIT_") }
        sanitized["GIT_OPTIONAL_LOCKS"] = "0"
        return sanitized
    }

    private enum DiffableFileKind: Equatable {
        case regular
        case symbolicLink
    }

    private static func diffableFileKind(_ path: String, repositoryRoot: String) -> DiffableFileKind? {
        var metadata = stat()
        let fullPath = URL(fileURLWithPath: repositoryRoot).appendingPathComponent(path).path
        guard lstat(fullPath, &metadata) == 0 else { return nil }
        let kind = metadata.st_mode & S_IFMT
        if kind == S_IFREG { return .regular }
        guard kind == S_IFLNK else { return nil }
        if stat(fullPath, &metadata) == 0 {
            let targetKind = metadata.st_mode & S_IFMT
            guard targetKind == S_IFREG || targetKind == S_IFDIR else { return nil }
        }
        return .symbolicLink
    }

    private static func symlinkPatch(path: String, repositoryRoot: String) throws -> Data {
        let fullPath = URL(fileURLWithPath: repositoryRoot).appendingPathComponent(path).path
        let target: String
        do {
            target = try FileManager.default.destinationOfSymbolicLink(atPath: fullPath)
        } catch {
            throw MobileWorkingTreeDiffLoadError(code: "invalid_data", message: "Could not read a symbolic link")
        }
        let oldPath = gitPatchPath("a/\(path)")
        let newPath = gitPatchPath("b/\(path)")
        var lines = target.components(separatedBy: "\n")
        let endsWithNewline = target.hasSuffix("\n")
        if endsWithNewline { lines.removeLast() }
        var text = "diff --git \(oldPath) \(newPath)\nnew file mode 120000\n--- /dev/null\n+++ \(newPath)\n@@ -0,0 +1,\(max(1, lines.count)) @@\n"
        for line in lines { text += "+\(line)\n" }
        if !endsWithNewline { text += "\\ No newline at end of file\n" }
        guard let data = text.data(using: .utf8) else {
            throw MobileWorkingTreeDiffLoadError(code: "invalid_data", message: "Symbolic link target is not valid UTF-8")
        }
        return data
    }

    private static func gitPatchPath(_ path: String) -> String {
        let requiresQuotes = path.unicodeScalars.contains { scalar in
            scalar.value < 0x20 || scalar.value == 0x7f || scalar == "\\" || scalar == "\""
        }
        guard requiresQuotes else { return path }
        var result = "\""
        for scalar in path.unicodeScalars {
            switch scalar {
            case "\\": result += "\\\\"
            case "\"": result += "\\\""
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            default: result.unicodeScalars.append(scalar)
            }
        }
        return result + "\""
    }

    /// Drains a pipe to EOF while retaining only the caller's bounded prefix.
    private static func drain(
        fileDescriptor: Int32,
        maximumBytes: Int,
        cancellationOnOverflow: MobileDiffProcessCancellation? = nil
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
                if count > retainedCount, !overflowed {
                    overflowed = true
                    cancellationOnOverflow?.cancel()
                }
            } else if count == 0 {
                break
            } else if errno != EINTR {
                break
            }
        }
        return (data, overflowed)
    }
}
