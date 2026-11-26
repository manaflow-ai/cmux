import CmuxFoundation
import Foundation

/// Owns the complete Git subprocess boundary used by TextBox file mentions.
struct TextBoxGitIgnoreProbe: Sendable {
    private let rootURL: URL

    init(rootURL: URL) {
        self.rootURL = rootURL
    }

    func isWorkTree() async -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "git",
            "-C", rootURL.path,
            "rev-parse",
            "--is-inside-work-tree"
        ]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let terminationStatus = observeTermination(of: process)

        do {
            try process.run()
        } catch {
            return false
        }
        return await terminationStatus.wait() == 0
    }

    func ignoredRelativePaths(_ relativePaths: [String]) async -> Set<String> {
        guard !relativePaths.isEmpty else { return [] }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "git",
            "-C", rootURL.path,
            "check-ignore",
            "--stdin"
        ]

        let stdin = Pipe()
        let stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        let terminationStatus = observeTermination(of: process)

        do {
            try process.run()
        } catch {
            return []
        }

        // The child owns duplicated copies after run() returns. Closing the
        // parent's child-side handles makes EOF and resource ownership explicit.
        try? stdin.fileHandleForReading.close()
        try? stdout.fileHandleForWriting.close()

        let inputHandle = stdin.fileHandleForWriting
        let outputHandle = stdout.fileHandleForReading
        let outputDescriptor = outputHandle.fileDescriptor
        defer {
            try? inputHandle.close()
            try? outputHandle.close()
        }

        // Capture only the Sendable descriptor in detached work. The local
        // Pipe keeps its FileHandle alive until this task has been awaited.
        let outputTask = Task.detached(priority: .utility) {
            ProcessPipeEndRead.reading(fileDescriptor: outputDescriptor)
        }

        let probePaths = relativePaths + relativePaths.map { "\($0)/" }
        let input = Data((probePaths.joined(separator: "\n") + "\n").utf8)
        let inputSucceeded: Bool
        do {
            try inputHandle.writeProcessPipeInput(input)
            try inputHandle.close()
            inputSucceeded = true
        } catch {
            try? inputHandle.close()
            inputSucceeded = false
        }

        let output = await outputTask.value
        let status = await terminationStatus.wait()
        guard inputSucceeded,
              output.readError == nil,
              status == 0 || status == 1,
              let outputText = String(data: output.data, encoding: .utf8) else {
            return []
        }

        return Set(outputText
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init))
    }

    private func observeTermination(of process: Process) -> TextBoxProcessTerminationStatus {
        let terminationStatus = TextBoxProcessTerminationStatus()
        process.terminationHandler = { process in
            let status = process.terminationStatus
            Task {
                await terminationStatus.finish(status: status)
            }
        }
        return terminationStatus
    }
}
