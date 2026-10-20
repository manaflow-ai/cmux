import CmuxNextWakeups
import Foundation

/// What one `git` run printed on its output and how it exited.
nonisolated struct MarkdownGitOutput: Equatable, Sendable {
    var status: Int32
    var output: String
}

/// Runs read-only `git` commands for the Markdown omnibar; tests may pass a fake.
nonisolated protocol MarkdownGitRunning: Sendable {
    /// `git -C folder <arguments>`; nil when git did not run or ran past its deadline.
    func run(_ arguments: [String], in folder: String) async -> MarkdownGitOutput?
}

/// `/usr/bin/git` with no prompts and no optional locks (a status never takes the index lock an
/// editor or agent may hold), stopped at a deadline so a hung filesystem never holds the bar.
nonisolated struct ProcessMarkdownGitRunner: MarkdownGitRunning {
    var timeout: Duration = .seconds(5)

    func run(_ arguments: [String], in folder: String) async -> MarkdownGitOutput? {
        guard folder.hasPrefix("/"), !folder.contains("\0") else { return nil }
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", folder] + arguments
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        process.environment = ProcessInfo.processInfo.environment.merging(
            ["GIT_OPTIONAL_LOCKS": "0", "GIT_TERMINAL_PROMPT": "0", "LC_ALL": "C"]) { _, ours in ours }
        do { try process.run() } catch { return nil }
        let running = process
        // The raw descriptor crosses into the reading task (a FileHandle is not Sendable); the
        // pipe stays open while `running` holds it as its output.
        let descriptor = output.fileHandleForReading.fileDescriptor
        // A one-shot deadline for this git run, cancelled as soon as the run returns.
        let deadline = DemandTimer(owner: "markdown-omnibar.git")
        deadline.schedule(after: timeout) { if running.isRunning { running.terminate() } }
        defer { deadline.cancel() }
        return await Task.detached(priority: .utility) {
            // concurrency-allow: blocking read and wait inside this detached utility task; git's
            // output for one file is small, and the deadline above ends a hung run.
            let data = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false).readDataToEndOfFile()
            // concurrency-allow: git closed its output (EOF above), so it has exited or is exiting.
            running.waitUntilExit()
            guard running.terminationReason == .exit else { return nil }
            return MarkdownGitOutput(status: running.terminationStatus, output: String(decoding: data, as: UTF8.self))
        }.value
    }
}
