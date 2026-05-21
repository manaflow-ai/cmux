import Foundation

struct CmuxExtensionWorktreeCreationResult: Sendable {
    let worktreePath: String
    let workspaceTitle: String
    let initialCommand: String
}

final class CmuxExtensionProcessTermination: @unchecked Sendable {
    private let lock = NSLock()
    private var status: Int32?
    private var continuation: CheckedContinuation<Int32, Never>?

    func complete(_ status: Int32) {
        let continuation: CheckedContinuation<Int32, Never>?
        lock.lock()
        if let pendingContinuation = self.continuation {
            self.continuation = nil
            continuation = pendingContinuation
        } else {
            self.status = status
            continuation = nil
        }
        lock.unlock()
        continuation?.resume(returning: status)
    }

    func wait() async -> Int32 {
        await withCheckedContinuation { continuation in
            let completedStatus: Int32?
            lock.lock()
            if let status {
                completedStatus = status
            } else {
                self.continuation = continuation
                completedStatus = nil
            }
            lock.unlock()

            if let completedStatus {
                continuation.resume(returning: completedStatus)
            }
        }
    }
}

enum CmuxExtensionWorktreePrototype {
    static func createWorktree(projectRootPath: String) async throws -> CmuxExtensionWorktreeCreationResult {
        try await Task.detached(priority: .userInitiated) {
            let projectRoot = URL(fileURLWithPath: projectRootPath, isDirectory: true).standardizedFileURL
            try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
            try await ensureGitRepository(at: projectRoot)
            try await ensureCmuxWorktreeDirectoryIsLocallyIgnored(projectRoot: projectRoot)

            let branchName = "cmux-sidebar-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(8).lowercased())"
            let worktreeRoot = projectRoot
                .appendingPathComponent(".cmux", isDirectory: true)
                .appendingPathComponent("worktrees", isDirectory: true)
            try FileManager.default.createDirectory(at: worktreeRoot, withIntermediateDirectories: true)
            let worktree = worktreeRoot.appendingPathComponent(branchName, isDirectory: true)
            try await run("git", ["-C", projectRoot.path, "worktree", "add", "-b", branchName, worktree.path, "HEAD"])
            try writeSampleDevServerFiles(in: worktree, projectName: projectRoot.lastPathComponent)

            let port = 4_100 + abs(branchName.hashValue % 800)
            let samplePath = shellEscaped(worktree.appendingPathComponent("cmux-sample-dev", isDirectory: true).path)
            return CmuxExtensionWorktreeCreationResult(
                worktreePath: worktree.path,
                workspaceTitle: branchName,
                initialCommand: "cd \(samplePath) && python3 -m http.server \(port)"
            )
        }.value
    }

    private static func ensureGitRepository(at projectRoot: URL) async throws {
        if (try? await run("git", ["-C", projectRoot.path, "rev-parse", "--is-inside-work-tree"])) != nil {
            return
        }
        throw NSError(
            domain: "CmuxExtensionWorktreePrototype",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Project root is not a git repository."]
        )
    }

    private static func ensureCmuxWorktreeDirectoryIsLocallyIgnored(projectRoot: URL) async throws {
        let output = try await runCapturingOutput("git", ["-C", projectRoot.path, "rev-parse", "--git-path", "info/exclude"])
        guard let rawPath = String(data: output, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !rawPath.isEmpty else {
            throw NSError(
                domain: "CmuxExtensionWorktreePrototype",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Could not resolve git exclude file."]
            )
        }

        let excludeURL = rawPath.hasPrefix("/")
            ? URL(fileURLWithPath: rawPath).standardizedFileURL
            : projectRoot.appendingPathComponent(rawPath).standardizedFileURL
        try FileManager.default.createDirectory(at: excludeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let existing = (try? String(contentsOf: excludeURL, encoding: .utf8)) ?? ""
        let alreadyIgnored = existing
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .contains { $0 == ".cmux" || $0 == ".cmux/" }
        guard !alreadyIgnored else { return }

        let separator = existing.isEmpty || existing.hasSuffix("\n") ? "" : "\n"
        let next = existing + separator + "# cmux extension worktrees\n.cmux/\n"
        try next.write(to: excludeURL, atomically: true, encoding: .utf8)
    }

    private static func writeSampleDevServerFiles(in worktree: URL, projectName: String) throws {
        let sample = worktree.appendingPathComponent("cmux-sample-dev", isDirectory: true)
        try FileManager.default.createDirectory(at: sample, withIntermediateDirectories: true)
        let escapedProject = projectName
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        let html = """
        <!doctype html>
        <html>
          <head><meta charset="utf-8"><title>cmux worktree</title></head>
          <body style="font: 15px -apple-system; padding: 32px;">
            <h1>\(escapedProject) worktree</h1>
            <p>This page is served from a git worktree created by CmuxExtensionKit.</p>
          </body>
        </html>
        """
        try html.write(to: sample.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
    }

    private static func run(_ executable: String, _ arguments: [String]) async throws {
        _ = try await runCapturingOutput(executable, arguments)
    }

    private static func runCapturingOutput(_ executable: String, _ arguments: [String]) async throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [executable] + arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let outputCollector = CmuxExtensionPipeOutputCollector(fileHandle: pipe.fileHandleForReading)
        let termination = CmuxExtensionProcessTermination()
        process.terminationHandler = { process in
            termination.complete(process.terminationStatus)
        }
        try process.run()
        let terminationStatus = await termination.wait()
        let outputData = await outputCollector.finish()
        guard terminationStatus == 0 else {
            let details = String(data: outputData, encoding: .utf8) ?? "command failed"
            throw NSError(
                domain: "CmuxExtensionWorktreePrototype",
                code: Int(terminationStatus),
                userInfo: [
                    NSLocalizedDescriptionKey: "Could not create worktree.",
                    "CmuxExtensionWorktreePrototypeDetails": details
                ]
            )
        }
        return outputData
    }

    private static func shellEscaped(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

final class CmuxExtensionPipeOutputCollector: @unchecked Sendable {
    private let fileHandle: FileHandle
    private let lock = NSLock()
    private var output = Data()
    private var isFinished = false

    init(fileHandle: FileHandle) {
        self.fileHandle = fileHandle
        fileHandle.readabilityHandler = { [weak self] handle in
            self?.append(handle.availableData)
        }
    }

    func finish() async -> Data {
        await withCheckedContinuation { continuation in
            fileHandle.readabilityHandler = nil
            let remainingOutput = fileHandle.readDataToEndOfFile()
            try? fileHandle.close()

            lock.lock()
            isFinished = true
            if !remainingOutput.isEmpty {
                output.append(remainingOutput)
            }
            let finalOutput = self.output
            lock.unlock()
            continuation.resume(returning: finalOutput)
        }
    }

    private func append(_ data: Data) {
        let shouldClose: Bool
        lock.lock()
        if isFinished {
            shouldClose = false
        } else if data.isEmpty {
            isFinished = true
            shouldClose = true
        } else {
            output.append(data)
            shouldClose = false
        }
        lock.unlock()

        if shouldClose {
            fileHandle.readabilityHandler = nil
        }
    }
}
